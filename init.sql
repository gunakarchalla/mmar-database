--
-- PostgreSQL database dump
--

-- Dumped from database version 13.8
-- Dumped by pg_dump version 14.2

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: logging; Type: SCHEMA; Schema: -; Owner: api
--

CREATE SCHEMA logging;


ALTER SCHEMA logging OWNER TO api;

--
-- Name: change_trigger(); Type: FUNCTION; Schema: public; Owner: api
--

CREATE OR REPLACE FUNCTION public.change_trigger() RETURNS trigger
    LANGUAGE plpgsql
    SECURITY DEFINER
AS
$$
BEGIN
    IF TG_OP = 'INSERT'
    THEN
        INSERT INTO logging.t_history (tabname, schemaname, operation, new_val, transaction, affected_uuid)
        VALUES (TG_RELNAME, TG_TABLE_SCHEMA, TG_OP, row_to_json(NEW), txid_current(), NEW.uuid);
        RETURN NEW;
    ELSIF TG_OP = 'UPDATE'
    THEN
        NEW.modification_time = now();
        INSERT INTO logging.t_history (tabname, schemaname, operation, new_val, old_val, transaction, affected_uuid)
        VALUES (TG_RELNAME, TG_TABLE_SCHEMA, TG_OP, row_to_json(NEW), row_to_json(OLD), txid_current(), OLD.uuid);
        RETURN NEW;
    ELSIF TG_OP = 'DELETE'
    THEN
        INSERT INTO logging.t_history
            (tabname, schemaname, operation, old_val, transaction, affected_uuid)
        VALUES (TG_RELNAME, TG_TABLE_SCHEMA, TG_OP, row_to_json(OLD), txid_current(), OLD.uuid);
        RETURN OLD;
    END IF;
END;
$$;

ALTER FUNCTION public.change_trigger() OWNER TO api;


create or replace function public.after_delete_metaobject_function() returns trigger
    language plpgsql
    SECURITY DEFINER
as
$$
BEGIN
    DELETE FROM public.metaobject WHERE uuid = OLD.uuid_metaobject;
    RETURN OLD;
END;
$$;

alter function public.after_delete_metaobject_function() owner to api;


GRANT EXECUTE ON FUNCTION public.after_delete_metaobject_function() TO PUBLIC;

GRANT EXECUTE ON FUNCTION public.after_delete_metaobject_function() TO api WITH GRANT OPTION;


CREATE OR REPLACE FUNCTION public.delete_and_return_violation(p_uuid UUID, user_uuid UUID DEFAULT NULL)
    RETURNS TABLE
            (
                uuid UUID,
                name VARCHAR(256),
                type VARCHAR(128),
                error VARCHAR(10)
            )
    LANGUAGE plpgsql
    SECURITY DEFINER
AS
$$
DECLARE
    v_tablename              text;
    v_object                 text;
    v_column_name            text;
    v_column_name_constraint text;
    v_type                   text;
    v_sql                    text;
    v_name                   text;
    v_attribute_uuid         text;
    v_has_right              BOOLEAN := FALSE;
    v_last_transaction       text;
BEGIN
    -- Check for user rights
    v_has_right := user_uuid IS NULL OR
                   EXISTS (SELECT *
                           FROM has_delete_right
                                    JOIN user_group ug ON has_delete_right.uuid_user_group = ug.uuid_metaobject
                                    JOIN has_user_user_group huug ON ug.uuid_metaobject = huug.uuid_user_group
                       WHERE has_delete_right.uuid_metaobject = p_uuid
                             AND huug.uuid_user = user_uuid)
        OR user_uuid = 'ff892138-77e0-47fe-a323-3fe0e1bf0240';

    IF NOT v_has_right THEN
        uuid := p_uuid;
        error := '403';
        RETURN NEXT;
        RETURN;
    END IF;

    -- Delete operation
    DELETE FROM metaobject WHERE metaobject.uuid = p_uuid;

    -- Get the last transaction ID for the deleted item
    SELECT th.transaction
    INTO v_last_transaction
    FROM logging.t_history th
    WHERE th.affected_uuid = p_uuid
    ORDER BY th.tstamp DESC
    LIMIT 1;

    raise notice 'v_last_transaction: %', v_last_transaction;

    FOR uuid, name IN (SELECT affected_uuid
                       FROM logging.t_history th
                       WHERE operation = 'DELETE'
                         AND transaction = v_last_transaction)
        LOOP
            RETURN NEXT;
        END LOOP;

EXCEPTION
    when sqlstate '23504' then
        v_attribute_uuid := substring(SQLERRM, 'an attribute type "(.+?)"');

        -- Assuming you have a table 'attribute' with columns 'uuid' and 'name'
        BEGIN
            SELECT name INTO v_name FROM attribute WHERE uuid = v_attribute_uuid;
            uuid := v_attribute_uuid;
            type := 'attribute type'; -- or set this based on your business logic
            error := '23504';
            RETURN NEXT;
        EXCEPTION
            WHEN OTHERS THEN
                -- Handle case where v_attribute_uuid is not found
                uuid := v_attribute_uuid;
                error := 'Not Found';
                RETURN NEXT;
        END;
    WHEN sqlstate '23503' THEN
        error := '23503';
        v_tablename := substring(SQLERRM, '" on table "(.+?)"');
        v_object := substring(SQLERRM, 'update or delete on table "(.+?)"');
        raise notice 'v_object: %', v_object;
        raise notice 'v_tablename: %', v_tablename;

        -- Handle table specific errors
        IF v_tablename LIKE '%role%' THEN
            v_type := 'role';
            v_column_name_constraint := 'uuid_role';
            v_column_name := CASE v_object
                                 WHEN 'scene_type' THEN 'uuid_scene_type'
                                 WHEN 'relationclass' THEN 'uuid_relationclass'
                                 WHEN 'class' THEN 'uuid_class'
                                 WHEN 'port' THEN 'uuid_port'

                                 ELSE NULL
                END;
            if v_object = 'role' then
                v_type := 'role instance';
                v_column_name_constraint := 'uuid_instance_object';
                v_column_name := 'uuid_role';
                v_sql := format(
                        'SELECT instance_object.uuid, instance_object.name FROM %I, instance_object WHERE instance_object.uuid = %I.%I AND %I.%I=$1',
                        v_tablename, v_tablename, v_column_name_constraint, v_tablename, v_column_name);

            end if;

        ELSIF v_tablename LIKE 'has_user_user_group' THEN
            v_type := 'user';
            v_column_name_constraint := 'uuid_user';
            v_column_name := 'uuid_user_group';

        ELSIF v_tablename = 'attribute_instance' THEN
            v_type := 'attribute instance';
            v_column_name_constraint := 'uuid_instance_object';
            v_column_name := 'uuid_attribute';
            v_sql := format(
                    'SELECT instance_object.uuid, instance_object.name FROM %I, instance_object WHERE instance_object.uuid = %I.%I AND %I.%I=$1',
                    v_tablename, v_tablename, v_column_name_constraint, v_tablename, v_column_name);

        ELSIF v_tablename = 'scene_instance' THEN
            v_type := 'scene instance';
            v_column_name_constraint := 'uuid_instance_object';
            v_column_name := 'uuid_scene_type';
            v_sql := format(
                    'SELECT instance_object.uuid, instance_object.name FROM %I, instance_object WHERE instance_object.uuid = %I.%I AND %I.%I=$1',
                    v_tablename, v_tablename, v_column_name_constraint, v_tablename, v_column_name);

        ELSIF v_tablename = 'class_instance' THEN
            SELECT CASE
                       WHEN uuid_relationclass IS NOT NULL THEN 'relationclass_instance'
                       ELSE 'class_instance'
                       END
            INTO v_tablename
            FROM class_instance
            WHERE uuid_class = p_uuid;

            IF v_tablename = 'relationclass_instance' THEN
                v_type := 'relationclass instance';
                v_column_name_constraint := 'uuid_class_instance';
                v_column_name := 'uuid_class';
                v_sql := format(
                        'SELECT instance_object.uuid, instance_object.name FROM class_instance, %I, instance_object WHERE instance_object.uuid = %I.%I AND class_instance.%I=$1',
                        v_tablename, v_tablename, v_column_name_constraint, v_column_name);
            ELSE
                v_type := 'class instance';
                v_column_name_constraint := 'uuid_instance_object';
                v_column_name := 'uuid_class';
                v_sql := format(
                        'SELECT instance_object.uuid, instance_object.name FROM %I, instance_object WHERE instance_object.uuid = %I.%I AND %I.%I=$1',
                        v_tablename, v_tablename, v_column_name_constraint, v_tablename, v_column_name);
            END IF;

        ELSIF v_tablename = 'port_instance' THEN
            v_type := 'port instance';
            v_column_name_constraint := 'uuid_instance_object';
            v_column_name := 'uuid_port';
            v_sql := format(
                    'SELECT instance_object.uuid, instance_object.name FROM %I, instance_object WHERE instance_object.uuid = %I.%I AND %I.%I=$1',
                    v_tablename, v_tablename, v_column_name_constraint, v_tablename, v_column_name);

        ELSIF v_tablename = 'attribute' THEN
            v_type := 'attribute';
            v_column_name_constraint := 'uuid_metaobject';
            v_column_name := 'attribute_type_uuid';

        ELSIF v_tablename = 'relationclass' THEN
            v_type := 'relationclass';
            v_column_name_constraint := 'uuid_class';
            v_column_name := 'uuid_role_from';
            v_sql := format(
                    'SELECT metaobject.uuid, metaobject.name FROM %I, metaobject WHERE metaobject.uuid = %I.%I AND (%I.role_from=$1) OR (%I.role_to=$1)',
                    v_tablename, v_tablename, v_column_name_constraint, v_tablename, v_tablename);

        ELSIF v_tablename = 'attribute_type' THEN
            v_type := 'attribute type';
            v_column_name_constraint := 'uuid_metaobject';
            v_column_name := 'uuid_role_reference';

        END IF;

        -- If v_sql hasn't been defined by the previous blocks
        IF v_sql IS NULL THEN
            v_sql := format(
                    'SELECT metaobject.uuid, metaobject.name FROM %I, metaobject WHERE metaobject.uuid = %I.%I AND %I.%I=$1',
                    v_tablename, v_tablename, v_column_name_constraint, v_tablename, v_column_name);
        END IF;

        raise notice 'v_sql: %', v_sql;
        type := v_type;

        -- Execute the SQL statement and return the result
        FOR uuid, name IN EXECUTE v_sql USING p_uuid
            LOOP
                RETURN NEXT;
            END LOOP;

END
$$;


ALTER FUNCTION public.delete_and_return_violation(UUID, UUID)
    OWNER TO api;

--
-- Name: delete_instance_parent(); Type: FUNCTION; Schema: public; Owner: api
--

CREATE FUNCTION public.delete_instance_parent() RETURNS trigger
    LANGUAGE plpgsql
AS
$$
BEGIN
    EXECUTE 'delete from public.instance_object io where io.uuid = $1 returning io.uuid' USING OLD.uuid_instance_object;
    RETURN OLD;
END;
$$;


ALTER FUNCTION public.delete_instance_parent() OWNER TO api;

--
-- Name: FUNCTION delete_instance_parent(); Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON FUNCTION public.delete_instance_parent() IS 'This trigger deletes the parent if no child is attached';


CREATE OR REPLACE FUNCTION public.delete_role_fromto_metaobject_entries()
    RETURNS TRIGGER AS
$$
BEGIN
    -- Assuming that the metaobject table has columns 'uuid' that match 'role_from' and 'role_to'
    DELETE FROM public.metaobject WHERE uuid = OLD.role_from;
    DELETE FROM public.metaobject WHERE uuid = OLD.role_to;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

ALTER FUNCTION public.delete_role_fromto_metaobject_entries() OWNER TO api;



CREATE OR REPLACE FUNCTION public.delete_relationclass_from_role_entries()
    RETURNS TRIGGER AS
$$
BEGIN
    DELETE
    FROM public.instance_object
    WHERE public.instance_object.uuid IN (SELECT uuid_role_instance_from
                                          FROM public.relationclass_instance
                                          WHERE uuid_role_instance_from = OLD.uuid_instance_object)
       OR public.instance_object.uuid IN (SELECT uuid_role_instance_to
                                          FROM public.relationclass_instance
                                          WHERE uuid_role_instance_to = OLD.uuid_instance_object)
       OR public.instance_object.uuid = OLD.uuid_has_reference_relationclass_instance;
    RETURN OLD;
end;

$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION public.delete_attribute_role_entries()
    RETURNS TRIGGER AS
$$
BEGIN
    DELETE FROM public.instance_object WHERE public.instance_object.uuid = OLD.uuid_has_reference_attribute_instance;
    RETURN OLD;
end;

$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION public.prevent_delete_role_attrType_ref()
    RETURNS TRIGGER AS
$$
BEGIN
    IF
        NOT EXISTS(SELECT 1
                   FROM public.role
                   WHERE uuid_metaobject = OLD.uuid
                     AND role.uuid_attribute_type IS NOT NULL)
    THEN
        RAISE EXCEPTION 'Cannot delete role % because it reference an attribute type %', OLD.uuid_metaobject, OLD.uuid_attribute_type
            USING ERRCODE = '23504';
    END IF;
    RETURN OLD;
end;

$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION public.delete_bendpoint_entries()
    RETURNS trigger AS 
$$
DECLARE
    middle_uuids uuid[];
BEGIN
    -- Extract the UUIDs from the line_points JSON array, ignoring first and last elements 
    -- we ignore them since they are class instances that can exist on their own. -> thus, do not delete them
    SELECT ARRAY(
        SELECT (elem::json ->> 'UUID')::uuid
        FROM unnest(OLD.line_points) WITH ORDINALITY AS t(elem, ord)
        WHERE ord > 1 AND ord < array_length(OLD.line_points, 1)
    ) INTO middle_uuids;

    -- Delete entries for middle UUIDs
    DELETE FROM public.instance_object WHERE uuid = ANY(middle_uuids);

    -- Delete the from and to UUIDs as before
    DELETE FROM public.instance_object WHERE uuid = OLD.uuid_role_instance_from;
    DELETE FROM public.instance_object WHERE uuid = OLD.uuid_role_instance_to;

    RETURN OLD;
END;

$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION public.delete_metaobject_by_uuid(
    uuid_to_delete uuid,
    user_uuid uuid DEFAULT NULL::uuid)
    RETURNS TABLE
            (
                deleted_uuid uuid
            )
    LANGUAGE 'plpgsql'
    COST 100
    VOLATILE PARALLEL UNSAFE
    ROWS 1000

AS
$BODY$
BEGIN

    IF (
        user_uuid = 'ff892138-77e0-47fe-a323-3fe0e1bf0240'
            OR user_uuid IS NULL
            OR EXISTS(SELECT 1
                      FROM has_delete_right
                               JOIN user_group ug ON has_delete_right.uuid_user_group = ug.uuid_metaobject
                               JOIN has_user_user_group huug ON ug.uuid_metaobject = huug.uuid_user_group
                      WHERE has_delete_right.uuid_metaobject = uuid_to_delete
                        AND huug.uuid_user = user_uuid))
    THEN
        DELETE FROM metaobject WHERE uuid = uuid_to_delete;
        RETURN QUERY
            SELECT affected_uuid
            FROM logging.t_history th
            WHERE operation = 'DELETE'
              AND transaction IN (SELECT th.transaction
                                  FROM logging.t_history th
                                  WHERE th.affected_uuid = uuid_to_delete
                                  ORDER BY th.tstamp DESC
                                  LIMIT 1);
    ELSE
        RAISE EXCEPTION 'Permission denied.';
    END IF;
END
$BODY$;

ALTER FUNCTION public.delete_metaobject_by_uuid(uuid, uuid)
    OWNER TO api;

GRANT EXECUTE ON FUNCTION public.delete_metaobject_by_uuid(uuid, uuid) TO PUBLIC;

GRANT EXECUTE ON FUNCTION public.delete_metaobject_by_uuid(uuid, uuid) TO api WITH GRANT OPTION;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: t_history; Type: TABLE; Schema: logging; Owner: api
--

CREATE TABLE logging.t_history
(
    id            integer NOT NULL,
    transaction   text,
    tstamp        timestamp without time zone DEFAULT now(),
    schemaname    text,
    tabname       text,
    operation     text,
    who           text                        DEFAULT CURRENT_USER,
    new_val       json,
    old_val       json,
    affected_uuid uuid
);


ALTER TABLE logging.t_history
    OWNER TO api;

--
-- Name: COLUMN t_history.affected_uuid; Type: COMMENT; Schema: logging; Owner: api
--

COMMENT ON COLUMN logging.t_history.affected_uuid IS 'This is the affected uuid by the operation';


--
-- Name: t_history_id_seq; Type: SEQUENCE; Schema: logging; Owner: api
--

CREATE SEQUENCE logging.t_history_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE logging.t_history_id_seq
    OWNER TO api;

--
-- Name: t_history_id_seq; Type: SEQUENCE OWNED BY; Schema: logging; Owner: api
--

ALTER SEQUENCE logging.t_history_id_seq OWNED BY logging.t_history.id;


--
-- Name: aggregator_class; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.aggregator_class
(
    uuid_class uuid NOT NULL
);


ALTER TABLE public.aggregator_class
    OWNER TO api;

CREATE TABLE public.procedure
(
    uuid_metaobject uuid not null,
    definition text
);

alter table public.procedure
    owner to api;

CREATE TABLE public.has_algorithm
(
    uuid_scene_type uuid not null,
    uuid_procedure uuid not null
);

alter table public.has_algorithm
    owner to api;

--
-- Name: assigned_to_scene; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.assigned_to_scene
(
    uuid_class_instance uuid NOT NULL,
    uuid_scene_instance uuid NOT NULL
);


ALTER TABLE public.assigned_to_scene
    OWNER TO api;

--
-- Name: attribute; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.attribute
(
    uuid_metaobject     uuid NOT NULL,
    multi_valued        boolean,
    default_value       text,
    attribute_type_uuid uuid NOT NULL,
    facets              text,
    min                 integer,
    max                 integer
);

comment on table public.attribute is 'this is the table for the meta attributes';
comment on column public.attribute.multi_valued is 'this is the flag if the attribute is multi valued';
comment on column public.attribute.default_value is 'this is the default value for the attribute';
comment on column public.attribute.facets is 'this is if the attribute is an enum type';

ALTER TABLE public.attribute
    OWNER TO api;

--
-- Name: attribute_instance; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.attribute_instance
(
    uuid_instance_object         uuid NOT NULL,
    uuid_attribute               uuid,
    is_propagated                boolean,
    value                        text,
    assigned_uuid_scene_instance uuid,
    assigned_uuid_class_instance uuid,
    assigned_uuid_port_instance  uuid,
    role_instance_from           uuid,
    table_attribute_reference    uuid,
    table_row                    integer
);


ALTER TABLE public.attribute_instance
    OWNER TO api;

--
-- Name: attribute_propagating_relationclass; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.attribute_propagating_relationclass
(
    uuid_relationclass uuid NOT NULL
);


ALTER TABLE public.attribute_propagating_relationclass
    OWNER TO api;

--
-- Name: attribute_type; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.attribute_type
(
    uuid_metaobject uuid NOT NULL,
    pre_defined     boolean,
    regex_value     text
);


ALTER TABLE public.attribute_type
    OWNER TO api;

--
-- Name: class; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.class
(
    uuid_metaobject uuid NOT NULL,
    is_reusable     boolean,
    is_abstract     boolean
);


ALTER TABLE public.class
    OWNER TO api;

--
-- Name: class_aggregation_reference; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.class_aggregation_reference
(
    uuid_class_instance           uuid NOT NULL,
    uuid_contained_class_instance uuid NOT NULL
);


ALTER TABLE public.class_aggregation_reference
    OWNER TO api;

--
-- Name: class_decomposition_reference; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.class_decomposition_reference
(
    uuid_class_instance            uuid NOT NULL,
    uuid_decomposed_class_instance uuid NOT NULL
);


ALTER TABLE public.class_decomposition_reference
    OWNER TO api;

--
-- Name: class_has_attributes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.class_has_attributes
(
    uuid_class     uuid NOT NULL,
    uuid_attribute uuid NOT NULL,
    sequence       integer,
    ui_component   text
);
comment on column public.class_has_attributes.sequence is 'The position of the attributes in the ui';
comment on column public.class_has_attributes.ui_component is 'The ui component for the attribute';


ALTER TABLE public.class_has_attributes
    OWNER TO api;

--
-- Name: port_has_attributes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.port_has_attributes
(
    uuid_port      uuid NOT NULL,
    uuid_attribute uuid NOT NULL,
    sequence       integer,
    ui_component   text
);
comment on column public.port_has_attributes.sequence is 'The position of the attributes in the ui';
comment on column public.port_has_attributes.ui_component is 'The ui component for the attribute';



ALTER TABLE public.port_has_attributes
    OWNER TO api;

--
-- Name: class_instance; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.class_instance
(
    uuid_instance_object         uuid NOT NULL,
    uuid_class                   uuid NOT NULL,
    uuid_relationclass           uuid,
    uuid_decomposable_class      uuid,
    uuid_aggregator_class        uuid,
    uuid_relationclass_bendpoint uuid
);


ALTER TABLE public.class_instance
    OWNER TO api;

--
-- Name: contains_aggreg_classes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.contains_aggreg_classes
(
    uuid_class            uuid NOT NULL,
    uuid_aggregator_class uuid NOT NULL
);


ALTER TABLE public.contains_aggreg_classes
    OWNER TO api;

--
-- Name: contains_aggreg_relationclasses; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.contains_aggreg_relationclasses
(
    uuid_relationclass    uuid NOT NULL,
    uuid_aggregator_class uuid NOT NULL
);


ALTER TABLE public.contains_aggreg_relationclasses
    OWNER TO api;

--
-- Name: contains_classes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.contains_classes
(
    uuid_class      uuid NOT NULL,
    uuid_scene_type uuid NOT NULL
);


ALTER TABLE public.contains_classes
    OWNER TO api;

--
-- Name: decomposable_class; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.decomposable_class
(
    uuid_class uuid NOT NULL
);


ALTER TABLE public.decomposable_class
    OWNER TO api;

--
-- Name: decomposable_into_aggregator_classes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.decomposable_into_aggregator_classes
(
    uuid_decomposable_class uuid NOT NULL,
    uuid_aggregator_class   uuid NOT NULL
);


ALTER TABLE public.decomposable_into_aggregator_classes
    OWNER TO api;

--
-- Name: decomposable_into_classes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.decomposable_into_classes
(
    uuid_decomposable_class uuid NOT NULL,
    uuid_class              uuid NOT NULL
);


ALTER TABLE public.decomposable_into_classes
    OWNER TO api;

--
-- Name: decomposable_into_scenes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.decomposable_into_scenes
(
    uuid_decomposable_class uuid NOT NULL,
    uuid_scene_type         uuid NOT NULL
);


ALTER TABLE public.decomposable_into_scenes
    OWNER TO api;

CREATE TABLE public.file
(
    type            varchar(128) not null,
    data            bytea        not null,
    uuid_metaobject uuid         not null
);


alter table public.file
    owner to api;


--
-- Name: TABLE file; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.file IS 'This is the table where the files are stored';


--
-- Name: generic_constraint; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.generic_constraint
(
    uuid                     uuid NOT NULL,
    name                     character varying(256),
    value                    text,
    assigned_uuid_metaobject uuid NOT NULL
);


ALTER TABLE public.generic_constraint
    OWNER TO api;

--
-- Name: has_delete_right; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.has_delete_right
(
    id integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    uuid_user_group      uuid,
    uuid_metaobject      uuid
);


ALTER TABLE public.has_delete_right
    OWNER TO api;

--
-- Name: has_delete_right_id_seq; Type: SEQUENCE; Schema: public; Owner: api
--
--
--
-- CREATE SEQUENCE public.has_delete_right_id_seq
--     AS integer
--     START WITH 1
--     INCREMENT BY 1
--     NO MINVALUE
--     NO MAXVALUE
--     CACHE 1;
--
--
-- ALTER TABLE public.has_delete_right_id_seq
--     OWNER TO api;
--
-- --
-- -- Name: has_delete_right_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: api
-- --
--
-- ALTER SEQUENCE public.has_delete_right_id_seq OWNED BY public.has_delete_right.id;
--
--
-- --
-- -- Name: has_delete_right_id_seq1; Type: SEQUENCE; Schema: public; Owner: api
-- --
-- ALTER TABLE public.has_delete_right
--     ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
--         SEQUENCE NAME public.has_delete_right_id_seq
--         START WITH 1
--         INCREMENT BY 1
--         NO MINVALUE
--         NO MAXVALUE
--         CACHE 1
--         );


--
-- Name: has_read_right; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.has_read_right
(
    id integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    uuid_user_group      uuid,
    uuid_metaobject      uuid
);


ALTER TABLE public.has_read_right
    OWNER TO api;

--
-- Name: has_read_right_id_seq; Type: SEQUENCE; Schema: public; Owner: api
--
--
-- CREATE SEQUENCE public.has_read_right_id_seq
--     AS integer
--     START WITH 1
--     INCREMENT BY 1
--     NO MINVALUE
--     NO MAXVALUE
--     CACHE 1;
--
--
--
-- ALTER TABLE public.has_read_right_id_seq
--     OWNER TO api;
--
-- --
-- -- Name: has_read_right_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: api
-- --
--
-- ALTER SEQUENCE public.has_read_right_id_seq OWNED BY public.has_read_right.id;
--
--
-- --
-- -- Name: has_read_right_id_seq1; Type: SEQUENCE; Schema: public; Owner: api
-- --
--
-- ALTER TABLE public.has_read_right
--     ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
--         SEQUENCE NAME public.has_read_right_id_seq1
--         START WITH 1
--         INCREMENT BY 1
--         NO MINVALUE
--         NO MAXVALUE
--         CACHE 1
--         );


--
-- Name: has_table_attribute; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.has_table_attribute
(
    sequence            integer,
    uuid_attribute_type uuid NOT NULL,
    uuid_attribute      uuid NOT NULL,
    ui_component        text NOT NULL DEFAULT 'text'
);


ALTER TABLE public.has_table_attribute
    OWNER TO api;

--
-- Name: TABLE has_table_attribute; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON TABLE public.has_table_attribute IS 'This table give the possibility to have a table as attribute';


--
-- Name: COLUMN has_table_attribute.uuid_attribute_type; Type: COMMENT; Schema: public; Owner: api
--

COMMENT ON COLUMN public.has_table_attribute.uuid_attribute_type IS 'This is the link to the attribute type "table x" for example';


--
-- Name: has_user_user_group; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.has_user_user_group
(
    uuid_user       uuid NOT NULL,
    uuid_user_group uuid NOT NULL
);


ALTER TABLE public.has_user_user_group
    OWNER TO api;

--
-- Name: has_write_right; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.has_write_right
(
    id integer NOT NULL GENERATED ALWAYS AS IDENTITY,
    uuid_user_group      uuid,
    uuid_metaobject      uuid
);


ALTER TABLE public.has_write_right
    OWNER TO api;

--
-- Name: has_write_right_id_seq; Type: SEQUENCE; Schema: public; Owner: api
--

-- CREATE SEQUENCE public.has_write_right_id_seq
--     AS integer
--     START WITH 1
--     INCREMENT BY 1
--     NO MINVALUE
--     NO MAXVALUE
--     CACHE 1;
--
--
-- ALTER TABLE public.has_write_right_id_seq
--     OWNER TO api;
--
-- --
-- -- Name: has_write_right_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: api
-- --
--
-- ALTER SEQUENCE public.has_write_right_id_seq OWNED BY public.has_write_right.id;
--
--
-- --
-- -- Name: has_write_right_id_seq1; Type: SEQUENCE; Schema: public; Owner: api
-- --
--
-- ALTER TABLE public.has_write_right
--     ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
--         SEQUENCE NAME public.has_write_right_id_seq1
--         START WITH 1
--         INCREMENT BY 1
--         NO MINVALUE
--         NO MAXVALUE
--         CACHE 1
--         );

--
-- Name: instance_object; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.instance_object
(
    uuid              uuid NOT NULL               DEFAULT gen_random_uuid(),
    creation_time     timestamp without time zone DEFAULT now(),
    modification_time timestamp without time zone DEFAULT now(),
    geometry               text,
    coordinates_2d         text,
    relative_coordinate_3d text,
    absolute_coordinate_3d text,
    rotation               text,
    visibility             boolean,
    custom_variables       text,
    name                   text,
    description            text
);


ALTER TABLE public.instance_object
    OWNER TO api;

--
-- Name: is_sub_scene; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.is_sub_scene
(
    uuid_scene_type     uuid NOT NULL,
    uuid_sub_scene_type uuid NOT NULL
);


ALTER TABLE public.is_sub_scene
    OWNER TO api;

--
-- Name: is_subclass_of; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.is_subclass_of
(
    uuid_super_class uuid NOT NULL,
    uuid_class       uuid NOT NULL
);


ALTER TABLE public.is_subclass_of
    OWNER TO api;

--
-- Name: metaobject; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.metaobject
(
    uuid              uuid NOT NULL               DEFAULT gen_random_uuid(),
    name                   character varying(256),
    description            character varying(256),
    creation_time     timestamp without time zone DEFAULT now(),
    modification_time timestamp without time zone DEFAULT now(),
    geometry               text,
    coordinates_2d         text,
    relative_coordinate_3d text,
    absolute_coordinate_3d text
);


ALTER TABLE public.metaobject
    OWNER TO api;

--
-- Name: port; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.port
(
    uuid_metaobject uuid NOT NULL,
    uuid_class      uuid,
    uuid_scene_type uuid
);


ALTER TABLE public.port
    OWNER TO api;

--
-- Name: port_instance; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.port_instance
(
    uuid_instance_object uuid NOT NULL,
    uuid_port            uuid NOT NULL,
    uuid_class_instance  uuid,
    uuid_scene_instance  uuid
);


ALTER TABLE public.port_instance
    OWNER TO api;

--
-- Name: propagation_attribute; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.propagation_attribute
(
    uuid_attribute_instance uuid NOT NULL,
    "Durability"            integer,
    "Mutability"            integer
);


ALTER TABLE public.propagation_attribute
    OWNER TO api;

--
-- Name: relationclass; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.relationclass
(
    uuid_class           uuid NOT NULL,
    role_from            uuid NOT NULL,
    role_to              uuid NOT NULL,
    uuid_class_bendpoint uuid
);


ALTER TABLE public.relationclass
    OWNER TO api;

--
-- Name: relationclass_instance; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.relationclass_instance
(
    uuid_class_instance     uuid NOT NULL,
    uuid_role_instance_from uuid NOT NULL,
    uuid_role_instance_to   uuid NOT NULL,
    line_points             text[]
);


ALTER TABLE public.relationclass_instance
    OWNER TO api;

--
-- Name: role; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.role
(
    uuid_metaobject     uuid NOT NULL,
    uuid_attribute_type uuid
);


ALTER TABLE public.role
    OWNER TO api;

--
-- Name: role_class_reference; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.role_class_reference
(
    uuid_role  uuid NOT NULL,
    uuid_class uuid NOT NULL,
    min        integer,
    max        integer
);


ALTER TABLE public.role_class_reference
    OWNER TO api;

--
-- Name: role_instance; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.role_instance
(
    uuid_instance_object                      uuid NOT NULL,
    uuid_role                                 uuid NOT NULL,
    uuid_has_reference_class_instance         uuid,
    uuid_has_reference_port_instance          uuid,
    uuid_has_reference_scene_instance         uuid,
    uuid_has_reference_attribute_instance     uuid,
    uuid_has_reference_relationclass_instance uuid
);


ALTER TABLE public.role_instance
    OWNER TO api;

--
-- Name: role_port_reference; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.role_port_reference
(
    uuid_role uuid NOT NULL,
    uuid_port uuid NOT NULL,
    min       integer,
    max       integer
);


ALTER TABLE public.role_port_reference
    OWNER TO api;

--
-- Name: role_relationclass_reference; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.role_relationclass_reference
(
    uuid_role          uuid,
    uuid_relationclass uuid,
    min                integer,
    max                integer
);


ALTER TABLE public.role_relationclass_reference
    OWNER TO api;

--
-- Name: role_scene_reference; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.role_scene_reference
(
    uuid_role       uuid NOT NULL,
    uuid_scene_type uuid NOT NULL,
    min             integer,
    max             integer
);


ALTER TABLE public.role_scene_reference
    OWNER TO api;

--
-- Name: role_attribute_reference; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.role_attribute_reference
(
    uuid_role uuid NOT NULL,
    uuid_attribute uuid NOT NULL,
    min       integer,
    max       integer
);


ALTER TABLE public.role_attribute_reference
    OWNER TO api;

--
-- Name: scene_decomposition_reference; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.scene_decomposition_reference
(
    uuid_class_instance uuid NOT NULL,
    uuid_scene_instance uuid NOT NULL
);


ALTER TABLE public.scene_decomposition_reference
    OWNER TO api;

--
-- Name: scene_group; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.scene_group
(
    uuid_metaobject uuid NOT NULL,
    is_subgroup_of  uuid
);


ALTER TABLE public.scene_group
    OWNER TO api;

--
-- Name: scene_has_attributes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.scene_has_attributes
(
    uuid_scene_type uuid NOT NULL,
    uuid_attribute  uuid NOT NULL,
    sequence        integer,
    ui_component    text
);
comment on column public.scene_has_attributes.sequence is 'The position of the attributes in the ui';
comment on column public.scene_has_attributes.ui_component is 'The ui component for the attribute';


ALTER TABLE public.scene_has_attributes
    OWNER TO api;

--
-- Name: scene_instance; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.scene_instance
(
    uuid_instance_object uuid NOT NULL,
    uuid_scene_type      uuid NOT NULL
);


ALTER TABLE public.scene_instance
    OWNER TO api;

--
-- Name: scene_instance_user_access; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.scene_instance_user_access
(
    uuid_scene_instance uuid NOT NULL,
    uuid_user           uuid NOT NULL,
    read_access         boolean,
    edit_access        boolean,
    delete_access       boolean
);


ALTER TABLE public.scene_instance_user_access
    OWNER TO api;

--
-- Name: scene_type; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.scene_type
(
    uuid_metaobject uuid NOT NULL
);


ALTER TABLE public.scene_type
    OWNER TO api;

--
-- Name: selected_propagation_attributes; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.selected_propagation_attributes
(
    uuid_attrib_progagating_relationclass uuid NOT NULL,
    uuid_attribute                        uuid NOT NULL,
    durability                            character varying(3),
    mutability                            character varying(3)
);


ALTER TABLE public.selected_propagation_attributes
    OWNER TO api;

--
-- Name: user_group; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.user_group
(
    uuid_metaobject           uuid    NOT NULL,
    can_create_scenetype      boolean not null default false,
    can_create_attribute      boolean not null default false,
    can_create_attribute_type boolean not null default false,
    can_create_class          boolean not null default false,
    can_create_relationclass  boolean not null default false,
    can_create_port           boolean not null default false,
    can_create_role           boolean not null default false,
    can_create_procedure  boolean not null default false,
    can_create_user_group boolean not null default false

);


ALTER TABLE public.user_group
    OWNER TO api;

create table public.can_create_instances
(
    uuid_user_group uuid not null,
    uuid_metaobject uuid not null
);

alter table public.can_create_instances
    owner to api;



--
-- Name: users; Type: TABLE; Schema: public; Owner: api
--

CREATE TABLE public.users
(
    uuid_metaobject uuid                   NOT NULL,
    username        character varying(256) NOT NULL,
    password text NOT NULL,
    salt            text,
    token           text
);


ALTER TABLE public.users
    OWNER TO api;

--
-- Name: t_history id; Type: DEFAULT; Schema: logging; Owner: api
--

ALTER TABLE ONLY logging.t_history
    ALTER COLUMN id SET DEFAULT nextval('logging.t_history_id_seq'::regclass);



-- example data


-- ---------------------
-- metaobjects
-- ---------------------
INSERT INTO public.metaobject (uuid, name, description, creation_time, modification_time, geometry, coordinates_2d,
                               relative_coordinate_3d, absolute_coordinate_3d)
VALUES ('03f0cbf8-0278-4c85-8130-28aed970284f', 'test', NULL, '2022-10-21 10:44:04.425429',
        '2022-10-21 10:44:04.425429', NULL, NULL, NULL, NULL);
INSERT INTO public.metaobject (uuid, name, description, creation_time, modification_time, geometry, coordinates_2d,
                               relative_coordinate_3d, absolute_coordinate_3d)
VALUES ('ff892138-77e0-47fe-a323-3fe0e1bf0240', 'admin', NULL, '2022-10-21 10:46:54.078601',
        '2022-10-21 10:46:54.078601', NULL, NULL, NULL, NULL);


--boolean
INSERT INTO public.metaobject (uuid, name, description, creation_time, modification_time, geometry, coordinates_2d,
                               relative_coordinate_3d, absolute_coordinate_3d)
VALUES ('8d77b476-ef09-40c0-a997-92233c4b8636', 'Enumeration', 'This ist the enumeration AttributeType',
        '2023-08-24 15:13:32.293508', '2023-08-25 12:11:26.571961', NULL, NULL, NULL, NULL);
--float
INSERT INTO public.metaobject (uuid, name, description, creation_time, modification_time, geometry, coordinates_2d,
                               relative_coordinate_3d, absolute_coordinate_3d)
VALUES ('00ce583a-9762-4700-af36-b4fdca7a9d3f', 'Float', 'This is the float attribute type',
        '2023-08-24 15:12:15.868455', '2023-08-25 12:10:34.279428', NULL, NULL, NULL, NULL);
--integer
INSERT INTO public.metaobject (uuid, name, description, creation_time, modification_time, geometry, coordinates_2d,
                               relative_coordinate_3d, absolute_coordinate_3d)
VALUES ('6f434afb-8a3a-4500-8287-8c8575340b10', 'Integer', NULL, '2023-08-25 12:11:26.571961',
        '2023-08-25 12:11:26.571961', NULL, NULL, NULL, NULL);
--string
INSERT INTO public.metaobject (uuid, name, description, creation_time, modification_time, geometry, coordinates_2d,
                               relative_coordinate_3d, absolute_coordinate_3d)
VALUES ('85897325-c2b3-4ca7-8902-8120300a08dc', 'String', NULL, '2023-08-24 15:10:11.789527',
        '2023-08-25 12:12:28.397052', '', NULL, NULL, NULL);
-- file
INSERT INTO public.metaobject (uuid, name, description, creation_time, modification_time, geometry, coordinates_2d,
                               relative_coordinate_3d, absolute_coordinate_3d)
VALUES ('2df15b5e-6b43-4911-b38b-0fc5747a8ee6', 'File', NULL, '2024-11-24 15:10:11.789527',
        '2024-11-24 15:10:11.789527', '', NULL, NULL, NULL);

-- mechanism
INSERT INTO public.metaobject (uuid, name, description, creation_time, modification_time, geometry, coordinates_2d,
                               relative_coordinate_3d, absolute_coordinate_3d)
VALUES ('a8e33bad-9eed-4a24-a4b2-406c5439d13a', 'Mechanism', NULL, '2025-03-20 15:10:11.789527',
        '2025-03-20 15:10:11.789527', '', NULL, NULL, NULL);



INSERT INTO public.users (uuid_metaobject, username, password, salt, token)
VALUES ('03f0cbf8-0278-4c85-8130-28aed970284f', 'test', '$2a$10$oPU3HTi7gV6tkKbBg6ZzFuqcgBlEosnvx0Ty9rsJLkM2A6rCrMBZS',
        NULL, NULL);
INSERT INTO public.users (uuid_metaobject, username, password, salt, token)
VALUES ('ff892138-77e0-47fe-a323-3fe0e1bf0240', 'admin', '$2a$10$VC0PBQ7djoHjtubEahV7XexPW.B8x7dDUBQ6l9LEiOjLMmewiWTJy',
        NULL, NULL);
-- ---------------------
-- attribute_types
-- ---------------------
--boolean
INSERT INTO public.attribute_type (uuid_metaobject, pre_defined, regex_value)
VALUES ('8d77b476-ef09-40c0-a997-92233c4b8636', true,
        '^([\x09\x0A\x0D\x20-\x7E]|[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2})*$');
--float
INSERT INTO public.attribute_type (uuid_metaobject, pre_defined, regex_value)
VALUES ('00ce583a-9762-4700-af36-b4fdca7a9d3f', false, '^[-+]?[0-9]*\.?[0-9]+([eE][-+]?[0-9]+)?$');
--integer
INSERT INTO public.attribute_type (uuid_metaobject, pre_defined, regex_value)
VALUES ('6f434afb-8a3a-4500-8287-8c8575340b10', true, '^([0-9])*$');
--string
INSERT INTO public.attribute_type (uuid_metaobject, pre_defined, regex_value)
VALUES ('85897325-c2b3-4ca7-8902-8120300a08dc', true,
        '^([\x09\x0A\x0D\x20-\x7E]|[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2})*$');
-- file
INSERT INTO public.attribute_type (uuid_metaobject, pre_defined, regex_value)
VALUES ('2df15b5e-6b43-4911-b38b-0fc5747a8ee6', true, '^([\x09\x0A\x0D\x20-\x7E]|[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2})*$');
-- mechanism
INSERT INTO public.attribute_type (uuid_metaobject, pre_defined, regex_value)
VALUES ('a8e33bad-9eed-4a24-a4b2-406c5439d13a', true, '^([\x09\x0A\x0D\x20-\x7E]|[\xC2-\xDF][\x80-\xBF]|\xE0[\xA0-\xBF][\x80-\xBF]|[\xE1-\xEC\xEE\xEF][\x80-\xBF]{2}|\xED[\x80-\x9F][\x80-\xBF]|\xF0[\x90-\xBF][\x80-\xBF]{2}|[\xF1-\xF3][\x80-\xBF]{3}|\xF4[\x80-\x8F][\x80-\xBF]{2})*$');

SELECT pg_catalog.setval('logging.t_history_id_seq', 432, true);


--
-- Name: has_delete_right_id_seq; Type: SEQUENCE SET; Schema: public; Owner: api
--

-- SELECT pg_catalog.setval('public.has_delete_right_id_seq', 1, false);


--
-- Name: has_delete_right_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: api
--

-- SELECT pg_catalog.setval('public.has_delete_right_id_seq1', 1, false);


--
-- Name: has_read_right_id_seq; Type: SEQUENCE SET; Schema: public; Owner: api
--

-- SELECT pg_catalog.setval('public.has_read_right_id_seq', 1, false);


--
-- Name: has_read_right_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: api
--

-- SELECT pg_catalog.setval('public.has_read_right_id_seq1', 1, false);


--
-- Name: has_write_right_id_seq; Type: SEQUENCE SET; Schema: public; Owner: api
--

-- SELECT pg_catalog.setval('public.has_write_right_id_seq', 1, false);


--
-- Name: has_write_right_id_seq1; Type: SEQUENCE SET; Schema: public; Owner: api
--

-- SELECT pg_catalog.setval('public.has_write_right_id_seq1', 1, false);


--
-- Name: aggregator_class aggregator_class_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.aggregator_class
    ADD CONSTRAINT aggregator_class_pkey PRIMARY KEY (uuid_class);


--
-- Name: assigned_to_scene assigned_to_scene_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.assigned_to_scene
    ADD CONSTRAINT assigned_to_scene_pkey PRIMARY KEY (uuid_class_instance, uuid_scene_instance);


--
-- Name: attribute_instance attribute_instance_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_instance
    ADD CONSTRAINT attribute_instance_pkey PRIMARY KEY (uuid_instance_object);


--
-- Name: attribute attribute_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute
    ADD CONSTRAINT attribute_pkey PRIMARY KEY (uuid_metaobject);


--
-- Name: attribute_propagating_relationclass attribute_propagating_relationclass_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_propagating_relationclass
    ADD CONSTRAINT attribute_propagating_relationclass_pkey PRIMARY KEY (uuid_relationclass);


--
-- Name: attribute_type attribute_type_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_type
    ADD CONSTRAINT attribute_type_pkey PRIMARY KEY (uuid_metaobject);



--
-- Name: class_aggregation_reference class_aggregation_reference_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_aggregation_reference
    ADD CONSTRAINT class_aggregation_reference_pkey PRIMARY KEY (uuid_class_instance, uuid_contained_class_instance);


--
-- Name: class_decomposition_reference class_decomposition_reference_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_decomposition_reference
    ADD CONSTRAINT class_decomposition_reference_pkey PRIMARY KEY (uuid_class_instance, uuid_decomposed_class_instance);


--
-- Name: class_has_attributes class_has_attributes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_has_attributes
    ADD CONSTRAINT class_has_attributes_pkey PRIMARY KEY (uuid_class, uuid_attribute);


--
-- Name: port_has_attributes port_has_attributes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port_has_attributes
    ADD CONSTRAINT port_has_attributes_pkey PRIMARY KEY (uuid_port, uuid_attribute);


--
-- Name: class_instance class_instance_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_instance
    ADD CONSTRAINT class_instance_pkey PRIMARY KEY (uuid_instance_object);


--
-- Name: class_instance class_instance_uuid_relationclass_uuid_instance_object_key; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_instance
    ADD CONSTRAINT class_instance_uuid_relationclass_uuid_instance_object_key UNIQUE (uuid_relationclass, uuid_instance_object);


--
-- Name: class class_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class
    ADD CONSTRAINT class_pkey PRIMARY KEY (uuid_metaobject);


--
-- Name: contains_aggreg_classes contains_aggreg_classes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_aggreg_classes
    ADD CONSTRAINT contains_aggreg_classes_pkey PRIMARY KEY (uuid_class, uuid_aggregator_class);


--
-- Name: contains_aggreg_relationclasses contains_aggreg_relationclasses_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_aggreg_relationclasses
    ADD CONSTRAINT contains_aggreg_relationclasses_pkey PRIMARY KEY (uuid_relationclass, uuid_aggregator_class);


--
-- Name: contains_classes contains_classes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_classes
    ADD CONSTRAINT contains_classes_pkey PRIMARY KEY (uuid_class, uuid_scene_type);


--
-- Name: decomposable_class decomposable_class_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_class
    ADD CONSTRAINT decomposable_class_pkey PRIMARY KEY (uuid_class);


--
-- Name: decomposable_into_aggregator_classes decomposable_into_aggregator_classes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_aggregator_classes
    ADD CONSTRAINT decomposable_into_aggregator_classes_pkey PRIMARY KEY (uuid_decomposable_class, uuid_aggregator_class);


--
-- Name: decomposable_into_classes decomposable_into_classes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_classes
    ADD CONSTRAINT decomposable_into_classes_pkey PRIMARY KEY (uuid_decomposable_class, uuid_class);


--
-- Name: decomposable_into_scenes decomposable_into_scenes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_scenes
    ADD CONSTRAINT decomposable_into_scenes_pkey PRIMARY KEY (uuid_decomposable_class, uuid_scene_type);



--
-- Name: generic_constraint generic_constraint_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.generic_constraint
    ADD CONSTRAINT generic_constraint_pkey PRIMARY KEY (uuid);


ALTER TABLE ONLY public.procedure
    ADD CONSTRAINT procedure_pkey PRIMARY KEY (uuid_metaobject);

ALTER TABLE ONLY public.has_algorithm
    ADD CONSTRAINT has_procedure_pkey PRIMARY KEY (uuid_scene_type, uuid_procedure);


--
-- Name: has_delete_right has_delete_right_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_delete_right
    ADD CONSTRAINT has_delete_right_pkey PRIMARY KEY (id);


--
-- Name: has_read_right has_read_right_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_read_right
    ADD CONSTRAINT has_read_right_pkey PRIMARY KEY (id);



--
-- Name: has_table_attribute has_table_attribute_pk; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_table_attribute
    ADD CONSTRAINT has_table_attribute_pk PRIMARY KEY (uuid_attribute, uuid_attribute_type);


--
-- Name: has_user_user_group has_user_user_group_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_user_user_group
    ADD CONSTRAINT has_user_user_group_pkey PRIMARY KEY (uuid_user, uuid_user_group);


--
-- Name: has_write_right has_write_right_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_write_right
    ADD CONSTRAINT has_write_right_pkey PRIMARY KEY (id);


--
-- Name: instance_object instance_object_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.instance_object
    ADD CONSTRAINT instance_object_pkey PRIMARY KEY (uuid);


--
-- Name: is_sub_scene is_sub_scene_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.is_sub_scene
    ADD CONSTRAINT is_sub_scene_pkey PRIMARY KEY (uuid_scene_type, uuid_sub_scene_type);


--
-- Name: is_subclass_of is_subclass_of_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.is_subclass_of
    ADD CONSTRAINT is_subclass_of_pkey PRIMARY KEY (uuid_super_class, uuid_class);


--
-- Name: metaobject metaobject_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.metaobject
    ADD CONSTRAINT metaobject_pkey PRIMARY KEY (uuid);


--
-- Name: port_instance port_instance_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port_instance
    ADD CONSTRAINT port_instance_pkey PRIMARY KEY (uuid_instance_object);


--
-- Name: port port_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port
    ADD CONSTRAINT port_pkey PRIMARY KEY (uuid_metaobject);


--
-- Name: propagation_attribute propagation_attribute_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.propagation_attribute
    ADD CONSTRAINT propagation_attribute_pkey PRIMARY KEY (uuid_attribute_instance);


--
-- Name: relationclass_instance relationclass_instance_pk; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass_instance
    ADD CONSTRAINT relationclass_instance_pk PRIMARY KEY (uuid_class_instance);


--
-- Name: relationclass relationclass_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass
    ADD CONSTRAINT relationclass_pkey PRIMARY KEY (uuid_class);


--
-- Name: role_class_reference role_class_reference_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_class_reference
    ADD CONSTRAINT role_class_reference_pkey PRIMARY KEY (uuid_role, uuid_class);


--
-- Name: role_instance role_instance_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_instance
    ADD CONSTRAINT role_instance_pkey PRIMARY KEY (uuid_instance_object);


--
-- Name: role role_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT role_pkey PRIMARY KEY (uuid_metaobject);


--
-- Name: role_port_reference role_port_reference_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_port_reference
    ADD CONSTRAINT role_port_reference_pkey PRIMARY KEY (uuid_role, uuid_port);


ALTER TABLE ONLY public.role_relationclass_reference
    ADD CONSTRAINT role_relationclass_reference_pkey UNIQUE (uuid_role, uuid_relationclass);


--
-- Name: role_scene_reference role_scene_reference_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_scene_reference
    ADD CONSTRAINT role_scene_reference_pkey PRIMARY KEY (uuid_role, uuid_scene_type);



ALTER TABLE ONLY public.role_attribute_reference
    ADD CONSTRAINT role_attribute_reference_pkey PRIMARY KEY (uuid_role, uuid_attribute);


--
-- Name: scene_decomposition_reference scene_decomposition_reference_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_decomposition_reference
    ADD CONSTRAINT scene_decomposition_reference_pkey PRIMARY KEY (uuid_class_instance, uuid_scene_instance);


--
-- Name: scene_group scene_group_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_group
    ADD CONSTRAINT scene_group_pkey PRIMARY KEY (uuid_metaobject);


--
-- Name: scene_has_attributes scene_has_attributes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_has_attributes
    ADD CONSTRAINT scene_has_attributes_pkey PRIMARY KEY (uuid_scene_type, uuid_attribute);


--
-- Name: scene_instance scene_instance_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_instance
    ADD CONSTRAINT scene_instance_pkey PRIMARY KEY (uuid_instance_object);


--
-- Name: scene_instance_user_access scene_instance_user_access_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_instance_user_access
    ADD CONSTRAINT scene_instance_user_access_pkey PRIMARY KEY (uuid_scene_instance, uuid_user);


--
-- Name: scene_type scene_type_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_type
    ADD CONSTRAINT scene_type_pkey PRIMARY KEY (uuid_metaobject);


--
-- Name: selected_propagation_attributes selected_propagation_attributes_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.selected_propagation_attributes
    ADD CONSTRAINT selected_propagation_attributes_pkey PRIMARY KEY (uuid_attrib_progagating_relationclass, uuid_attribute);


--
-- Name: user_group user_group_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_group
    ADD CONSTRAINT user_group_pkey PRIMARY KEY (uuid_metaobject);


ALTER TABLE ONLY public.can_create_instances
    ADD CONSTRAINT can_create_instances_pkey PRIMARY KEY (uuid_metaobject);

--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (uuid_metaobject);



--
-- Name: file_uuid_uindex; Type: INDEX; Schema: public; Owner: api
--

CREATE UNIQUE INDEX file_uuid_uindex ON public.file USING btree (uuid_metaobject);

-- Then, create the trigger on the relationclass table
CREATE TRIGGER trigger_delete_metaobject_entries
    AFTER DELETE
    ON public.relationclass
    FOR EACH ROW
EXECUTE FUNCTION public.delete_role_fromto_metaobject_entries();



-- Then, create the trigger on the relationclass table
CREATE TRIGGER trigger_delete_bendpoint
    AFTER DELETE
    ON public.relationclass_instance
    FOR EACH ROW
EXECUTE FUNCTION public.delete_bendpoint_entries();


CREATE TRIGGER trigger_relationclass_from_role
    AFTER DELETE
    ON public.role_instance
    FOR EACH ROW
EXECUTE FUNCTION public.delete_relationclass_from_role_entries();


CREATE TRIGGER trigger_attribute_role
    AFTER DELETE
    ON public.role_instance
    FOR EACH ROW
EXECUTE FUNCTION public.delete_attribute_role_entries();

--CREATE TRIGGER trigger_prevent_delete_role
--    BEFORE DELETE ON public.metaobject
--    FOR EACH ROW EXECUTE FUNCTION public.prevent_delete_role_attrType_ref();

--
-- Name: attribute_instance delete_instance_parent; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER delete_instance_parent
    AFTER DELETE
    ON public.attribute_instance
    FOR EACH ROW
EXECUTE FUNCTION public.delete_instance_parent();


--
-- Name: class_instance delete_instance_parent; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER delete_instance_parent
    AFTER DELETE
    ON public.class_instance
    FOR EACH ROW
EXECUTE FUNCTION public.delete_instance_parent();


--
-- Name: port_instance delete_instance_parent; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER delete_instance_parent
    AFTER DELETE
    ON public.port_instance
    FOR EACH ROW
EXECUTE FUNCTION public.delete_instance_parent();


--
-- Name: role_instance delete_instance_parent; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER delete_instance_parent
    AFTER DELETE
    ON public.role_instance
    FOR EACH ROW
EXECUTE FUNCTION public.delete_instance_parent();


--
-- Name: scene_instance delete_instance_parent; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER delete_instance_parent
    AFTER DELETE
    ON public.scene_instance
    FOR EACH ROW
EXECUTE FUNCTION public.delete_instance_parent();


--
-- Name: instance_object t; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER t
    BEFORE INSERT OR DELETE OR UPDATE
    ON public.instance_object
    FOR EACH ROW
EXECUTE FUNCTION public.change_trigger();


--
-- Name: metaobject t; Type: TRIGGER; Schema: public; Owner: api
--

CREATE TRIGGER t
    BEFORE INSERT OR DELETE OR UPDATE
    ON public.metaobject
    FOR EACH ROW
EXECUTE FUNCTION public.change_trigger();


CREATE TRIGGER after_delete_role_trigger
    AFTER DELETE
    ON public.role
    FOR EACH ROW
EXECUTE FUNCTION public.after_delete_metaobject_function();

CREATE TRIGGER after_delete_port_trigger
    AFTER DELETE
    ON public.port
    FOR EACH ROW
EXECUTE FUNCTION public.after_delete_metaobject_function();

ALTER TABLE ONLY public.procedure
    ADD CONSTRAINT procedure_metaobject_fkey FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY public.has_algorithm
    ADD CONSTRAINT has_procedure_procedure_fkey FOREIGN KEY (uuid_procedure) REFERENCES public.procedure (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY public.has_algorithm
    ADD CONSTRAINT has_procedure_scene_type_fkey FOREIGN KEY (uuid_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;

--
-- Name: aggregator_class fk_aggregator_class_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.aggregator_class
    ADD CONSTRAINT fk_aggregator_class_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assigned_to_scene fk_assigned_to_scene_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.assigned_to_scene
    ADD CONSTRAINT fk_assigned_to_scene_class_instance FOREIGN KEY (uuid_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: assigned_to_scene fk_assigned_to_scene_scene_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.assigned_to_scene
    ADD CONSTRAINT fk_assigned_to_scene_scene_instance FOREIGN KEY (uuid_scene_instance) REFERENCES public.scene_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: attribute fk_attribute_attribute_type; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute
    ADD CONSTRAINT fk_attribute_attribute_type FOREIGN KEY (attribute_type_uuid) REFERENCES public.attribute_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;

--
-- Name: attribute_instance fk_attribute_instance_assigned_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_instance
    ADD CONSTRAINT fk_attribute_instance_assigned_class_instance FOREIGN KEY (assigned_uuid_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: attribute_instance fk_attribute_instance_assigned_port_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_instance
    ADD CONSTRAINT fk_attribute_instance_assigned_port_instance FOREIGN KEY (assigned_uuid_port_instance) REFERENCES public.port_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: attribute_instance fk_attribute_instance_role_instance_from; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_instance
    ADD CONSTRAINT fk_attribute_instance_role_instance_from FOREIGN KEY (role_instance_from) REFERENCES public.role_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE set null;


--
-- Name: attribute_instance fk_attribute_instance_assigned_scene_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_instance
    ADD CONSTRAINT fk_attribute_instance_assigned_scene_instance FOREIGN KEY (assigned_uuid_scene_instance) REFERENCES public.scene_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: attribute_instance fk_attribute_instance_attribute; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_instance
    ADD CONSTRAINT fk_attribute_instance_attribute FOREIGN KEY (uuid_attribute) REFERENCES public.attribute (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: attribute_instance fk_attribute_instance_instance_object; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_instance
    ADD CONSTRAINT fk_attribute_instance_instance_object FOREIGN KEY (uuid_instance_object) REFERENCES public.instance_object (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: attribute_instance fk_attribute_instance_table_attribute; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_instance
    ADD CONSTRAINT fk_attribute_instance_table_attribute FOREIGN KEY (table_attribute_reference) REFERENCES public.attribute_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: attribute fk_attribute_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute
    ADD CONSTRAINT fk_attribute_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: attribute_propagating_relationclass fk_attribute_propagating_relationclass_relationclass; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_propagating_relationclass
    ADD CONSTRAINT fk_attribute_propagating_relationclass_relationclass FOREIGN KEY (uuid_relationclass) REFERENCES public.relationclass (uuid_class) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: attribute_type fk_attribute_type_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.attribute_type
    ADD CONSTRAINT fk_attribute_type_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: has_table_attribute fk_attribute_type_uuid; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_table_attribute
    ADD CONSTRAINT fk_attribute_type_uuid FOREIGN KEY (uuid_attribute_type) REFERENCES public.attribute_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: has_table_attribute fk_attribute_uuid; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_table_attribute
    ADD CONSTRAINT fk_attribute_uuid FOREIGN KEY (uuid_attribute) REFERENCES public.attribute (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class_aggregation_reference fk_class_aggregation_reference_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_aggregation_reference
    ADD CONSTRAINT fk_class_aggregation_reference_class_instance FOREIGN KEY (uuid_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class_aggregation_reference fk_class_aggregation_reference_contained_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_aggregation_reference
    ADD CONSTRAINT fk_class_aggregation_reference_contained_class_instance FOREIGN KEY (uuid_contained_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: is_subclass_of fk_class_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.is_subclass_of
    ADD CONSTRAINT fk_class_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class_decomposition_reference fk_class_decomposition_reference_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_decomposition_reference
    ADD CONSTRAINT fk_class_decomposition_reference_class_instance FOREIGN KEY (uuid_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class_decomposition_reference fk_class_decomposition_reference_decomposed_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_decomposition_reference
    ADD CONSTRAINT fk_class_decomposition_reference_decomposed_class_instance FOREIGN KEY (uuid_decomposed_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class_has_attributes fk_class_has_attributes_attribute; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_has_attributes
    ADD CONSTRAINT fk_class_has_attributes_attribute FOREIGN KEY (uuid_attribute) REFERENCES public.attribute (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class_has_attributes fk_class_has_attributes_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_has_attributes
    ADD CONSTRAINT fk_class_has_attributes_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: port_has_attributes fk_port_has_attributes_attribute; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port_has_attributes
    ADD CONSTRAINT fk_port_has_attributes_attribute FOREIGN KEY (uuid_attribute) REFERENCES public.attribute (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: port_has_attributes fk_port_has_attributes_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port_has_attributes
    ADD CONSTRAINT fk_port_has_attributes_port FOREIGN KEY (uuid_port) REFERENCES public.port (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class_instance fk_class_instance_instance_object; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_instance
    ADD CONSTRAINT fk_class_instance_instance_object FOREIGN KEY (uuid_instance_object) REFERENCES public.instance_object (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class fk_class_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class
    ADD CONSTRAINT fk_class_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: port_instance fk_connected_to_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port_instance
    ADD CONSTRAINT fk_connected_to_class_instance FOREIGN KEY (uuid_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: port_instance fk_connected_to_scene_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port_instance
    ADD CONSTRAINT fk_connected_to_scene_instance FOREIGN KEY (uuid_scene_instance) REFERENCES public.scene_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: contains_classes fk_constains_classes_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_classes
    ADD CONSTRAINT fk_constains_classes_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: contains_aggreg_classes fk_contains_aggreg_classes_aggregator_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_aggreg_classes
    ADD CONSTRAINT fk_contains_aggreg_classes_aggregator_class FOREIGN KEY (uuid_aggregator_class) REFERENCES public.aggregator_class (uuid_class) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: contains_aggreg_classes fk_contains_aggreg_classes_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_aggreg_classes
    ADD CONSTRAINT fk_contains_aggreg_classes_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: contains_aggreg_relationclasses fk_contains_aggreg_relationclasses_aggregator_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_aggreg_relationclasses
    ADD CONSTRAINT fk_contains_aggreg_relationclasses_aggregator_class FOREIGN KEY (uuid_aggregator_class) REFERENCES public.aggregator_class (uuid_class) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: contains_aggreg_relationclasses fk_contains_aggreg_relationclasses_relationclass; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_aggreg_relationclasses
    ADD CONSTRAINT fk_contains_aggreg_relationclasses_relationclass FOREIGN KEY (uuid_relationclass) REFERENCES public.relationclass (uuid_class) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: contains_classes fk_contains_classes_scene; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.contains_classes
    ADD CONSTRAINT fk_contains_classes_scene FOREIGN KEY (uuid_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: decomposable_class fk_decomposable_class_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_class
    ADD CONSTRAINT fk_decomposable_class_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: decomposable_into_aggregator_classes fk_decomposable_into_aggregator_classes_aggregator_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_aggregator_classes
    ADD CONSTRAINT fk_decomposable_into_aggregator_classes_aggregator_class FOREIGN KEY (uuid_aggregator_class) REFERENCES public.aggregator_class (uuid_class) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: decomposable_into_aggregator_classes fk_decomposable_into_aggregator_classes_decomposable_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_aggregator_classes
    ADD CONSTRAINT fk_decomposable_into_aggregator_classes_decomposable_class FOREIGN KEY (uuid_decomposable_class) REFERENCES public.decomposable_class (uuid_class) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: decomposable_into_classes fk_decomposable_into_classes_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_classes
    ADD CONSTRAINT fk_decomposable_into_classes_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: decomposable_into_classes fk_decomposable_into_classes_decomposable_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_classes
    ADD CONSTRAINT fk_decomposable_into_classes_decomposable_class FOREIGN KEY (uuid_decomposable_class) REFERENCES public.decomposable_class (uuid_class) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: decomposable_into_scenes fk_decomposable_into_scenes_decomposable_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_scenes
    ADD CONSTRAINT fk_decomposable_into_scenes_decomposable_class FOREIGN KEY (uuid_decomposable_class) REFERENCES public.decomposable_class (uuid_class) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: decomposable_into_scenes fk_decomposable_into_scenes_scene; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.decomposable_into_scenes
    ADD CONSTRAINT fk_decomposable_into_scenes_scene FOREIGN KEY (uuid_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: generic_constraint fk_generic_constraint_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.generic_constraint
    ADD CONSTRAINT fk_generic_constraint_metaobject FOREIGN KEY (assigned_uuid_metaobject) REFERENCES public.metaobject (uuid) on update cascade on delete cascade;


--
-- Name: has_delete_right fk_has_delete_right_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_delete_right
    ADD CONSTRAINT fk_has_delete_right_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: has_delete_right fk_has_delete_right_user_group; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_delete_right
    ADD CONSTRAINT fk_has_delete_right_user_group FOREIGN KEY (uuid_user_group) REFERENCES public.user_group (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY public.has_delete_right
    ADD CONSTRAINT unique_usergroup_metaobject_delete
    UNIQUE (uuid_user_group, uuid_metaobject);


--
-- Name: has_read_right fk_has_read_right_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_read_right
    ADD CONSTRAINT fk_has_read_right_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: has_read_right fk_has_read_right_user_group; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_read_right
    ADD CONSTRAINT fk_has_read_right_user_group FOREIGN KEY (uuid_user_group) REFERENCES public.user_group (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY public.has_read_right
    ADD CONSTRAINT unique_usergroup_metaobject_read
    UNIQUE (uuid_user_group, uuid_metaobject);


--
-- Name: has_user_user_group fk_has_user_user_group_user; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_user_user_group
    ADD CONSTRAINT fk_has_user_user_group_user FOREIGN KEY (uuid_user) REFERENCES public.users (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: has_user_user_group fk_has_user_user_group_user_group; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_user_user_group
    ADD CONSTRAINT fk_has_user_user_group_user_group FOREIGN KEY (uuid_user_group) REFERENCES public.user_group (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: has_write_right fk_has_write_right_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_write_right
    ADD CONSTRAINT fk_has_write_right_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: has_write_right fk_has_write_right_user_group; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.has_write_right
    ADD CONSTRAINT fk_has_write_right_user_group FOREIGN KEY (uuid_user_group) REFERENCES public.user_group (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY public.has_write_right
    ADD CONSTRAINT unique_usergroup_metaobject_write
    UNIQUE (uuid_user_group, uuid_metaobject);



ALTER TABLE ONLY public.role
    ADD CONSTRAINT fk_role_attribute_type FOREIGN KEY (uuid_attribute_type) REFERENCES public.attribute_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;
--
-- Name: relationclass_instance fk_instance_object; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass_instance
    ADD CONSTRAINT fk_instance_object FOREIGN KEY (uuid_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: relationclass_instance fk_instance_role_from; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass_instance
    ADD CONSTRAINT fk_instance_role_from FOREIGN KEY (uuid_role_instance_from) REFERENCES public.role_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: relationclass_instance fk_instance_role_to; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass_instance
    ADD CONSTRAINT fk_instance_role_to FOREIGN KEY (uuid_role_instance_to) REFERENCES public.role_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: class_instance fk_is_class_instance_aggregator_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_instance
    ADD CONSTRAINT fk_is_class_instance_aggregator_class FOREIGN KEY (uuid_aggregator_class) REFERENCES public.aggregator_class (uuid_class) ON UPDATE CASCADE ON DELETE RESTRICT;


ALTER TABLE ONLY public.class_instance
    ADD CONSTRAINT fk_relationclass_bendpoint FOREIGN KEY (uuid_relationclass_bendpoint) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;

--
-- Name: class_instance fk_is_class_instance_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_instance
    ADD CONSTRAINT fk_is_class_instance_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: class_instance fk_is_class_instance_decomposable_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_instance
    ADD CONSTRAINT fk_is_class_instance_decomposable_class FOREIGN KEY (uuid_decomposable_class) REFERENCES public.decomposable_class (uuid_class) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: class_instance fk_is_class_instance_relationclass; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.class_instance
    ADD CONSTRAINT fk_is_class_instance_relationclass FOREIGN KEY (uuid_relationclass) REFERENCES public.relationclass (uuid_class) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: port_instance fk_is_port_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port_instance
    ADD CONSTRAINT fk_is_port_instance FOREIGN KEY (uuid_port) REFERENCES public.port (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: scene_instance fk_is_scene_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_instance
    ADD CONSTRAINT fk_is_scene_instance FOREIGN KEY (uuid_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: is_sub_scene fk_is_sub_scene_scene; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.is_sub_scene
    ADD CONSTRAINT fk_is_sub_scene_scene FOREIGN KEY (uuid_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: is_sub_scene fk_is_sub_scene_sub_scene; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.is_sub_scene
    ADD CONSTRAINT fk_is_sub_scene_sub_scene FOREIGN KEY (uuid_sub_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: port fk_port_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port
    ADD CONSTRAINT fk_port_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: port_instance fk_port_instance_instance_object; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port_instance
    ADD CONSTRAINT fk_port_instance_instance_object FOREIGN KEY (uuid_instance_object) REFERENCES public.instance_object (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: port fk_port_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port
    ADD CONSTRAINT fk_port_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: port fk_port_scene; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.port
    ADD CONSTRAINT fk_port_scene FOREIGN KEY (uuid_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: propagation_attribute fk_propagation_attribute_instance_attribute_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.propagation_attribute
    ADD CONSTRAINT fk_propagation_attribute_instance_attribute_instance FOREIGN KEY (uuid_attribute_instance) REFERENCES public.attribute_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: relationclass fk_relationclass_bendpoints; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass
    ADD CONSTRAINT fk_relationclass_bendpoints FOREIGN KEY (uuid_class_bendpoint) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE set null;


--
-- Name: relationclass fk_relationclass_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass
    ADD CONSTRAINT fk_relationclass_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_class_reference fk_role_class_reference_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_class_reference
    ADD CONSTRAINT fk_role_class_reference_class FOREIGN KEY (uuid_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: role_class_reference fk_role_class_reference_role; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_class_reference
    ADD CONSTRAINT fk_role_class_reference_role FOREIGN KEY (uuid_role) REFERENCES public.role (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: relationclass fk_role_from; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass
    ADD CONSTRAINT fk_role_from FOREIGN KEY (role_from) REFERENCES public.role (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;



--
-- Name: role_instance fk_role_instance_instance_object; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_instance
    ADD CONSTRAINT fk_role_instance_instance_object FOREIGN KEY (uuid_instance_object) REFERENCES public.instance_object (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_instance fk_role_instance_reference_attribute_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_instance
    ADD CONSTRAINT fk_role_instance_reference_attribute_instance FOREIGN KEY (uuid_has_reference_attribute_instance) REFERENCES public.attribute_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_instance fk_role_instance_reference_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_instance
    ADD CONSTRAINT fk_role_instance_reference_class_instance FOREIGN KEY (uuid_has_reference_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_instance fk_role_instance_reference_port_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_instance
    ADD CONSTRAINT fk_role_instance_reference_port_instance FOREIGN KEY (uuid_has_reference_port_instance) REFERENCES public.port_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_instance fk_role_instance_reference_relationclass_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_instance
    ADD CONSTRAINT fk_role_instance_reference_relationclass_instance FOREIGN KEY (uuid_has_reference_relationclass_instance) REFERENCES public.relationclass_instance (uuid_class_instance) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_instance fk_role_instance_reference_scene_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_instance
    ADD CONSTRAINT fk_role_instance_reference_scene_instance FOREIGN KEY (uuid_has_reference_scene_instance) REFERENCES public.scene_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_instance fk_role_instance_role_type; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_instance
    ADD CONSTRAINT fk_role_instance_role_type FOREIGN KEY (uuid_role) REFERENCES public.role (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: role fk_role_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role
    ADD CONSTRAINT fk_role_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_port_reference fk_role_port_reference_port; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_port_reference
    ADD CONSTRAINT fk_role_port_reference_port FOREIGN KEY (uuid_port) REFERENCES public.port (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: role_port_reference fk_role_port_reference_role; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_port_reference
    ADD CONSTRAINT fk_role_port_reference_role FOREIGN KEY (uuid_role) REFERENCES public.role (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_relationclass_reference fk_role_relationclass_reference_relationclass; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_relationclass_reference
    ADD CONSTRAINT fk_role_relationclass_reference_relationclass FOREIGN KEY (uuid_relationclass) REFERENCES public.relationclass (uuid_class) ON UPDATE CASCADE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;


--
-- Name: role_relationclass_reference fk_role_relationclass_reference_role; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_relationclass_reference
    ADD CONSTRAINT fk_role_relationclass_reference_role FOREIGN KEY (uuid_role) REFERENCES public.role (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_scene_reference fk_role_scene_reference_role; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_scene_reference
    ADD CONSTRAINT fk_role_scene_reference_role FOREIGN KEY (uuid_role) REFERENCES public.role (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


ALTER TABLE ONLY public.role_attribute_reference
    ADD CONSTRAINT fk_role_attribute_reference_role FOREIGN KEY (uuid_role) REFERENCES public.role (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: role_scene_reference fk_role_scene_reference_scene; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.role_scene_reference
    ADD CONSTRAINT fk_role_scene_reference_scene FOREIGN KEY (uuid_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;

ALTER TABLE ONLY public.role_attribute_reference
    ADD CONSTRAINT fk_role_attribute_reference_attribute FOREIGN KEY (uuid_attribute) REFERENCES public.attribute (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: relationclass fk_role_to; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.relationclass
    ADD CONSTRAINT fk_role_to FOREIGN KEY (role_to) REFERENCES public.role (uuid_metaobject) ON UPDATE CASCADE ON DELETE RESTRICT DEFERRABLE INITIALLY DEFERRED;


--
-- Name: scene_decomposition_reference fk_scene_decomposition_reference_class_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_decomposition_reference
    ADD CONSTRAINT fk_scene_decomposition_reference_class_instance FOREIGN KEY (uuid_class_instance) REFERENCES public.class_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_decomposition_reference fk_scene_decomposition_reference_scene_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_decomposition_reference
    ADD CONSTRAINT fk_scene_decomposition_reference_scene_instance FOREIGN KEY (uuid_scene_instance) REFERENCES public.scene_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_group fk_scene_group_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_group
    ADD CONSTRAINT fk_scene_group_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_group fk_scene_group_subgroup; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_group
    ADD CONSTRAINT fk_scene_group_subgroup FOREIGN KEY (is_subgroup_of) REFERENCES public.scene_group (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_has_attributes fk_scene_has_attributes_attribute; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_has_attributes
    ADD CONSTRAINT fk_scene_has_attributes_attribute FOREIGN KEY (uuid_attribute) REFERENCES public.attribute (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_has_attributes fk_scene_has_attributes_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_has_attributes
    ADD CONSTRAINT fk_scene_has_attributes_class FOREIGN KEY (uuid_scene_type) REFERENCES public.scene_type (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_instance fk_scene_instance_instance_object; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_instance
    ADD CONSTRAINT fk_scene_instance_instance_object FOREIGN KEY (uuid_instance_object) REFERENCES public.instance_object (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_instance_user_access fk_scene_instance_user_access_scene_instance; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_instance_user_access
    ADD CONSTRAINT fk_scene_instance_user_access_scene_instance FOREIGN KEY (uuid_scene_instance) REFERENCES public.scene_instance (uuid_instance_object) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_instance_user_access fk_scene_instance_user_access_user; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_instance_user_access
    ADD CONSTRAINT fk_scene_instance_user_access_user FOREIGN KEY (uuid_user) REFERENCES public.users (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: scene_type fk_scene_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.scene_type
    ADD CONSTRAINT fk_scene_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: selected_propagation_attributes fk_selected_propagation_attributes_attribute; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.selected_propagation_attributes
    ADD CONSTRAINT fk_selected_propagation_attributes_attribute FOREIGN KEY (uuid_attribute) REFERENCES public.attribute (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: selected_propagation_attributes fk_selected_propagation_attributes_relationclass; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.selected_propagation_attributes
    ADD CONSTRAINT fk_selected_propagation_attributes_relationclass FOREIGN KEY (uuid_attrib_progagating_relationclass) REFERENCES public.attribute_propagating_relationclass (uuid_relationclass) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: is_subclass_of fk_super_class_class; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.is_subclass_of
    ADD CONSTRAINT fk_super_class_class FOREIGN KEY (uuid_super_class) REFERENCES public.class (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: user_group fk_user_group_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.user_group
    ADD CONSTRAINT fk_user_group_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;


ALTER TABLE ONLY public.can_create_instances
    ADD CONSTRAINT fk_can_create_instances_user_group FOREIGN KEY (uuid_user_group) REFERENCES public.user_group (uuid_metaobject) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY public.can_create_instances
    ADD CONSTRAINT fk_can_create_instances_meta_object FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;

ALTER TABLE ONLY public.can_create_instances
    ADD CONSTRAINT unique_usergroup_metaobject_create
    UNIQUE (uuid_user_group, uuid_metaobject);
--
-- Name: users fk_user_metaobject; Type: FK CONSTRAINT; Schema: public; Owner: api
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT fk_user_metaobject FOREIGN KEY (uuid_metaobject) REFERENCES public.metaobject (uuid) ON UPDATE CASCADE ON DELETE CASCADE;



alter table only public.file
    add constraint file_pkey primary key (uuid_metaobject);

alter table public.file
    add constraint fk_file_metaobject foreign key (uuid_metaobject) references public.metaobject (uuid) on delete cascade on update cascade;

comment on table public.file is 'this is the inheritance implementation of the file';

comment on column public.file.type is 'this is the mime type';

comment on column public.file.data is 'This is the data in base64';

comment on column public.file.uuid_metaobject is 'This is the uuid of the linked metaobject';

comment on constraint fk_file_metaobject on public.file is 'this is the link to the metaobject';



--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: logging; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api IN SCHEMA logging GRANT ALL ON SEQUENCES TO api;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: logging; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api IN SCHEMA logging GRANT ALL ON TABLES TO api;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: -; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api REVOKE ALL ON SEQUENCES FROM api;
ALTER DEFAULT PRIVILEGES FOR ROLE api GRANT ALL ON SEQUENCES TO api WITH GRANT OPTION;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: -; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api REVOKE ALL ON FUNCTIONS FROM api;
ALTER DEFAULT PRIVILEGES FOR ROLE api GRANT ALL ON FUNCTIONS TO api WITH GRANT OPTION;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: -; Owner: api
--

ALTER DEFAULT PRIVILEGES FOR ROLE api REVOKE ALL ON TABLES FROM api;
ALTER DEFAULT PRIVILEGES FOR ROLE api GRANT ALL ON TABLES TO api WITH GRANT OPTION;


--
-- PostgreSQL database dump complete
--


