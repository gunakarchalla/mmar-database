# MMAR Metamodeling Platform - Database Project

This project is part of the MMAR Metamodeling Platform, focusing on the database component.

## Installation

To install the database, please refer to the readme of the [MMAR repository](https://github.com/MM-AR/mmar) or the Wiki Entry of the [MMAR Manual Installation](https://github.com/MM-AR/mmar/wiki/Manual-MMAR-Installation).


## Audit trail

Two tables in the `logging` schema record what happened.

`logging.t_history` is written by the `public.change_trigger()` trigger on every insert,
update and delete of `metaobject` and `instance_object`. Besides the old and new row it
records `uuid_user`, the platform user responsible for the change.

It used to carry a `who` column defaulting to `CURRENT_USER`. That column was dropped: the
trigger is `SECURITY DEFINER`, so `CURRENT_USER` resolved to the owner of the function rather
than to the role that connected, and every row recorded the same value whoever made the
change. `uuid_user` answers the question it was meant to answer.

The API server publishes the acting user for the duration of a transaction:

```sql
SELECT set_config('mmar.uuid_user', '<uuid of the user>', true);
```

`public.current_app_user()` reads it back, returning `NULL` when it is absent or malformed,
so a change made outside the API server is recorded with `uuid_user IS NULL` rather than
being rejected. The setting is transaction local, so it cannot leak between two requests
sharing a pooled connection.

`logging.t_security_event` is written by the API server itself and holds the authentication
and privilege trail: sign ins, rejected tokens, granted and revoked access rights, and
refused requests. It carries no foreign key on `uuid_user` on purpose: an audit record has
to outlive the account it refers to, and a failed sign in has no account at all.

```sql
-- who changed a given object, most recent first
SELECT h.tstamp, h.operation, u.username
FROM logging.t_history h
         LEFT JOIN public.users u ON u.uuid_metaobject = h.uuid_user
WHERE h.affected_uuid = '<uuid>'
ORDER BY h.tstamp DESC;

-- failed sign ins per address over the last day
SELECT ip, count(*)
FROM logging.t_security_event
WHERE event = 'login'
  AND outcome = 'failure'
  AND tstamp > now() - interval '1 day'
GROUP BY ip
ORDER BY 2 DESC;
```


## Contributing

We welcome contributions! Please follow these steps:

1. Fork the development branche of the repository you want to work on.
2. Create a new branch (`git checkout -b feature/your-feature`).
3. Commit your changes (`git commit -am 'Add new feature'`).
4. Push to the branch (`git push origin feature/your-feature`).
5. Create a new Pull Request.

Contributions must be documented to be merged into the project. If you contribute something to the project, please document the according changes into the Wiki, or the readme.

## License

This repository is licensed under the GNU AFFERO GENERAL PUBLIC LICENSE Version 3. 

The GNU Affero General Public License (GNU AGPL) is a free, copyleft license published by the Free Software Foundation in November 2007, and based on the GNU GPL version 3 and the Affero General Public License. It is intended for software designed to be run over a network, adding a provision requiring that the corresponding source code of modified versions of the software be prominently offered to all users who interact with the software over a network (https://en.wikipedia.org/wiki/GNU_Affero_General_Public_License).

The GNU AGPL is specifically designed to ensure cooperation with the community in the case of network server software. The licenses for most software are designed to take away your freedom to share and change the works. By contrast, the GNU AGPL is intended to guarantee your freedom to share and change all versions of a program–to make sure it remains free software for all its users (https://www.gnu.org/licenses/agpl-3.0.en.html).

This means that any kind of published change done to the repository must be published again under the same license. For more information have a look at the LICENSE file.
