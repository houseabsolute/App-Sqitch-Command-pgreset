# NAME

App::Sqitch::Command::pgreset - Reset your Pg Sqitch changes

# VERSION

version 0.01

# SYNOPSIS

    sqitch pgreset [options]

# DESCRIPTION

This is a sqitch command to "reset" your Postgres database changes. What does
that mean?

Basically, it replaces all of your existing changes with one or two
changes. There is always one changes that create your tables, views, domains,
etc. If you have functions or stored procedures, those are created in their
own separate changes.

In order to do this, it needs to be able to connect to a Postgres instance and
create a database, which it will drop at the end of the reset process. The
steps this command takes are:

- Creates a new empty database.
- Deploys your existing changes to that database.
- Runs `pg_dump` to dump the newly created database.
- Moves the existing changes to a directory named `archive/YYYY-MM-DD` with the
current date.
- Starts a new sqitch project in the current directory with `sqitch init`.
- Takes the `pg_dump` output and separates it into two files. One contains
functions, procedures, and comments on those things. The other file contains
everything else.

    Separating out the functions and procedures allows you to update these via the
    `sqitch rework` command, which is a more VCS-friendly way of managing these.

- Adds the newly created files with `sqitch add`.
- Prints out some SQL that you will need to run against your production
databases manually before deploying the new sqitch project.

# WHY IS THIS USEFUL?

There are two main reasons this is useful.

The first is that it can be very hard to understand the state of your
database's structure after dozens or hundreds of Sqitch changes. You can't
open just a few Sqitch change files to figure out the state of the database,
as any given table might have been changed many times across many change
files.

The second is for speed. If you are regularly creating databases from scratch
by applying these changes, then it's much faster to apply a few files rather
than dozens. In particular, if you create databases as part of your testing,
doing a reset can signficantly improve test and CI speed.

# SUPPORT

Bugs may be submitted at [https://github.com/houseabsolute/App-Sqitch-Command-pgreset/issues](https://github.com/houseabsolute/App-Sqitch-Command-pgreset/issues).

# SOURCE

The source code repository for App-Sqitch-Command-pgreset can be found at [https://github.com/houseabsolute/App-Sqitch-Command-pgreset](https://github.com/houseabsolute/App-Sqitch-Command-pgreset).

# AUTHOR

Dave Rolsky <autarch@urth.org>

# COPYRIGHT AND LICENSE

This software is Copyright (c) 2022 by ActiveState, Inc.

This is free software, licensed under:

    The Artistic License 2.0 (GPL Compatible)

The full text of the license can be found in the
`LICENSE` file included with this distribution.
