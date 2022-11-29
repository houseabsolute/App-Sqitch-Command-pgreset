package App::Sqitch::Command::pgreset;

use v5.010;

use strict;
use warnings;
use autodie qw( :all );
use namespace::autoclean;

our $VERSION = '0.01';

use App::Sqitch::Types qw( Dir File Target );
use App::Sqitch::X     qw(hurl);
use DateTime;
use File::pushd;
use FindBin               qw( $Bin );
use IPC::Run3             qw( run3 );
use Path::Class           qw( tempdir );
use Types::Common::String qw( NonEmptyStr );
use Types::Standard       qw( Str );

use Moo;
## no critic (TestingAndDebugging::ProhibitNoWarnings)
no warnings 'experimental::postderef', 'experimental::signatures';

extends 'App::Sqitch::Command';
with 'App::Sqitch::Role::ContextCommand';
with 'App::Sqitch::Role::ConnectingCommand';

has target => (
    is  => 'ro',
    isa => Str,
);

has _real_target => (
    is  => 'rw',
    isa => Target,
);

has _temp_dir => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub { tempdir( CLEANUP => 1 ) },
);

has _reset_name => (
    is      => 'ro',
    isa     => NonEmptyStr,
    lazy    => 1,
    default => sub {
        my $self = shift;
        'reset-' . $self->_today;
    },
);

has _dump_file => (
    is      => 'ro',
    isa     => File,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->_temp_dir->file( $self->_reset_name . '.sql' );
    },
);

has _cwd => (
    is      => 'ro',
    isa     => Dir,
    lazy    => 1,
    default => sub {
        dir('.')->absolute,;
    },
);

has _deploy_schema_file => (
    is      => 'ro',
    isa     => File,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->_cwd->file(
            'deploy',
            'initial-schema-' . $self->_today . '.sql'
        );
    },
);

has _deploy_functions_file => (
    is      => 'ro',
    isa     => File,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->_cwd->file(
            'deploy',
            'initial-functions-' . $self->_today . '.sql'
        );
    },
);

has _project => (
    is      => 'ro',
    isa     => NonEmptyStr,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->_real_target->plan->project;
    },
);

has _db_name => (
    is      => 'ro',
    isa     => NonEmptyStr,
    lazy    => 1,
    default => sub {
        my $self = shift;
        $self->_project . '-sqitch-reset';
    },
);

has _today => (
    is      => 'ro',
    isa     => NonEmptyStr,
    lazy    => 1,
    default => sub { DateTime->today( time_zone => 'local' )->ymd },
);

sub options {
    return qw(
        target|t=s
    );
}

sub configure {
    my ( $class, $config, $opt ) = @_;

    my %params;
    for my $key (qw(target)) {
        $params{$key} = $opt->{$key} if exists $opt->{$key};
    }

    return \%params;
}

sub execute {
    my $self = shift;

    my ( $targets, $changes ) = $self->parse_args(
        target => $self->target,
        args   => \@_,
    );

    my $target = shift @{$targets};
    $self->warn(
        __x(
            'Too many targets specified; connecting to {target}',
            target => $target->name,
        )
    ) if @{$targets};

    $self->_real_target($target);
    my $engine = $target->engine;
    if ( $engine->name ne 'PostgreSQL' ) {
        hurl __x(
            'The pgreset sqitch command only works with Postgres but your target is a '
                . $engine->name
                . ' database',
        );
    }

    $self->_dump_database;
    $self->_archive_existing_sqitch_files;
    $self->_start_new_sqitch;
    $self->_write_deploy_files;
    $self->_add_verify_and_revert;
    $self->_sqitch_add_dump;
    $self->_write_sqitch_reset_sql;

    return $self;
}

sub _dump_database {
    my $self = shift;

    my $db_uri = $self->_real_target->uri;
    $db_uri->dbname( $self->_db_name );
    my @cmd_args;
    if ( $db_uri->host ) {
        push @cmd_args, '--host', $db_uri->host;
    }
    if ( $db_uri->_port ) {
        push @cmd_args, '--port', $db_uri->_port;
    }
    if ( $db_uri->user ) {
        push @cmd_args, '--username', $db_uri->user;
    }
    local $ENV{PGPASSWORD} = $db_uri->password if $db_uri->password;

    my $ok = eval {
        $self->sqitch->run( 'createdb', @cmd_args, $self->_db_name );
        $self->sqitch->run( 'sqitch', 'deploy', '--verify', $db_uri );
        $self->sqitch->run(
            'pg_dump',
            '--exclude-schema=sqitch',
            '--no-owner',
            '--no-privileges',
            '--no-tablespaces',
            '--file=' . $self->_dump_file,
            @cmd_args,
            $self->_db_name,
        );
        1;
    };
    my $err = $@;
    $self->sqitch->run( 'dropdb', '--if-exists', $self->_db_name );
    die $err unless $ok;

    return;
}

sub _archive_existing_sqitch_files {
    my $self = shift;

    my $archive_dir = $self->_cwd->subdir( 'archive', $self->_today );
    ## no critic (ValuesAndExpressions::ProhibitLeadingZeros)
    $archive_dir->mkpath( 0, 0755 );
    $archive_dir->subdir('lib')->mkpath( 0, 0755 );

    for my $path (qw( sqitch.plan deploy verify revert )) {
        say "Moving $path to $archive_dir" or die $!;
        $self->_cwd->file($path)->move_to( $archive_dir->file($path) );
    }

    return;
}

sub _start_new_sqitch {
    my $self = shift;

    say 'Running sqitch init' or die $!;
    my $dir = pushd( $self->_cwd );
    $self->sqitch->run(
        qw( sqitch --quiet init --engine pg ),
        $self->_project
    );

    return;
}

#use re 'debug';

my $func_re = qr/
\Q--
-- Name: \E[^;]+\([^\)]*\)\Q; Type: \E(?:FUNCTION|PROCEDURE)\Q; Schema: public; Owner: -
--

\E
(?<definition>
CREATE\ (?:FUNCTION|PROCEDURE)\ .+?\n
.+?
\$_?\$;)
\n+
/sx;

my $comment_re = qr/
\Q--
-- Name: \E(?:FUNCTION|PROCEDURE)\ [^;]+\Q; Type: COMMENT; Schema: public; Owner: -
--\E
\n+
(?<comment>COMMENT\ ON\ (?:FUNCTION|PROCEDURE)\ .+?;)
\n+
/sx;

sub _write_deploy_files {
    my $self = shift;

    my $sql = $self->_dump_file->slurp;
    my @funcs;
    while ( $sql =~ s/$func_re(?:$comment_re)?\n*// ) {
        my $func    = $+{definition};
        my $comment = $+{comment} // q{};

        $func    =~ s/\n$//;
        $comment =~ s/\n$//;

        push @funcs, $func . "\n\n" . $comment . "\n";
    }
    if (@funcs) {
        my $func_sql = join "\n", @funcs;
        $self->_deploy_functions_file->spew($func_sql);
    }

    $self->_deploy_schema_file->spew($sql);

    return;
}

sub _add_verify_and_revert {
    my $self = shift;

    my @files = $self->_deploy_schema_file;
    if ( -f $self->_deploy_functions_file ) {
        push @files, $self->_deploy_functions_file;
    }
    for my $name ( map { $_->basename } @files ) {
        $self->_cwd->file( 'verify', $name )->spew(<<'EOF');
-- There is nothing to verify for this change.
EOF

        $self->_cwd->file( 'revert', $name )->spew(<<'EOF');
-- To revert simply drop the database.
EOF
    }
}

sub _sqitch_add_dump {
    my $self = shift;

    my $dir = pushd( $self->_cwd );
    $self->sqitch->run(
        'sqitch', 'add',
        '--quiet',
        '--change-name', $self->_deploy_schema_file->basename =~ s/\.sql$//r,
        '--note', 'Deployment for database as it existed on ' . $self->_today,
    );
    if ( -f $self->_deploy_functions_file ) {
        $self->sqitch->run(
            'sqitch', 'add',
            '--quiet',
            '--change-name',
            $self->_deploy_functions_file->basename =~ s/\.sql$//r,
            '--note', 'Add functions as they existed on ' . $self->_today,
        );
    }

    return;
}

sub _write_sqitch_reset_sql {
    my $self = shift;

    my $project    = $self->_project;
    my $reset_name = $self->_reset_name;

    # from https://gist.github.com/theory/e7d432e69296e3672446
    say <<"EOF" or die $!;

In order to finish the reset, connect to your deployed database and run the
following command:

BEGIN;
DELETE FROM sqitch.tags WHERE change_id IN (
    SELECT change_id FROM sqitch.changes WHERE project = '$project'
);
DELETE FROM sqitch.dependencies WHERE change_id IN (
    SELECT change_id FROM sqitch.changes WHERE project = '$project'
);
DELETE FROM sqitch.changes WHERE project = '$project';
DELETE FROM sqitch.changes WHERE project = '$project';
DELETE FROM sqitch.events WHERE project = '$project';
DELETE FROM sqitch.projects WHERE project = '$project';
COMMIT;

Then run this command:

sqitch deploy --log-only \$db_uri
EOF
}

__PACKAGE__->meta->make_immutable;

1;

# ABSTRACT: Reset your Pg Sqitch changes

__END__

=encoding UTF-8

=head1 SYNOPSIS

  sqitch pgreset [options]

=head1 DESCRIPTION

This is a sqitch command to "reset" your Postgres database changes. What does
that mean?

Basically, it replaces all of your existing changes with one or two
changes. There is always one changes that create your tables, views, domains,
etc. If you have functions or stored procedures, those are created in their
own separate changes.

In order to do this, it needs to be able to connect to a Postgres instance and
create a database, which it will drop at the end of the reset process. The
steps this command takes are:

=over 4

=item *

Creates a new empty database.

=item *

Deploys your existing changes to that database.

=item *

Runs C<pg_dump> to dump the newly created database.

=item *

Moves the existing changes to a directory named F<archive/YYYY-MM-DD> with the
current date.

=item *

Starts a new sqitch project in the current directory with C<sqitch init>.

=item *

Takes the C<pg_dump> output and separates it into two files. One contains
functions, procedures, and comments on those things. The other file contains
everything else.

Separating out the functions and procedures allows you to update these via the
C<sqitch rework> command, which is a more VCS-friendly way of managing these.

=item *

Adds the newly created files with C<sqitch add>.

=item *

Prints out some SQL that you will need to run against your production
databases manually before deploying the new sqitch project.

=back

=head1 WHY IS THIS USEFUL?

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

=cut
