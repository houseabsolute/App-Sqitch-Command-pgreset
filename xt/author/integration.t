use v5.010;

use strict;
use warnings;

use Test2::V0;
use Test2::Plugin::NoWarnings;

use File::pushd qw( pushd );
use IPC::Run3 qw( run3 );
use Path::Tiny  qw( tempdir );

my $dir    = tempdir();
my $pushed = pushd($dir);

my $db_name = 'pgreset-integration-test';
my $db_uri  = "db:pg:$db_name";

_run_or_die( qw( dropdb --if-exists ), $db_name );
_run_or_die( 'createdb',               $db_name );

_run_or_die( qw( sqitch init integration-test --engine pg --target ), $db_uri );
_run_or_die(qw( sqitch add -c first -n first ));
_run_or_die(qw( sqitch add -r first -c second -n second ));

my $first = <<'EOF';
-- Deploy test:first to pg

CREATE TABLE t1 (
    t1_id  BIGSERIAL  PRIMARY KEY,
    name   TEXT       NOT NULL,
    size   INT
);

CREATE INDEX t1_name ON t1 (name);

CREATE TYPE mood AS ENUM ('sad', 'ok', 'happy');

CREATE DOMAIN us_postal_code AS TEXT
CHECK(
   VALUE ~ '^\d{5}$'
OR VALUE ~ '^\d{5}-\d{4}$'
);

CREATE TABLE t2 (
    t2_id    INT     PRIMARY KEY,
    t1_id    BIGINT  NOT NULL  REFERENCES t1 (t1_id),
    mood     mood,
    code     us_postal_code
);
EOF
$dir->child(qw( deploy first.sql ))->spew_utf8($first);

my $second = <<'EOF';
-- Deploy test:second to pg

BEGIN;

CREATE TABLE t3 (
   size   INT,
   smell  TEXT
);

COMMIT;
EOF
$dir->child(qw( deploy second.sql ))->spew_utf8($second);

_run_or_die(qw( sqitch deploy ));

ok(1);

sub _run_or_die {
    my @cmd  = @_;

    diag "Running [@cmd]";

    run3(
        \@cmd,
        undef,
        \*STDOUT,
        \*STDERR,
    );
    if ($?) {
        my $cmd = join q{ }, @cmd;
        my $err = "Error running $cmd\n";
        $err .= "  * Got a non-zero exit code from $cmd: "
            . ( $? >> 8 ) . "\n";
        die $err;
    }

    return;
}

done_testing();
