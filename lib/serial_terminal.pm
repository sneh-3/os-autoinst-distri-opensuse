# SUSE's openQA tests
#
# Copyright 2016-2019 SUSE LLC
# SPDX-License-Identifier: FSFAP
package serial_terminal;
use 5.018;
use warnings;
use testapi;
use Utils::Architectures;
use utils;
use autotest;
use base 'Exporter';
use Exporter;
use bmwqemu ();
use version_utils qw(is_sle is_leap is_sle_micro);
use Mojo::Util qw(b64_encode b64_decode sha1_sum trim);
use Mojo::File 'path';
use File::Basename;
use File::Temp 'tempfile';

BEGIN {
    our @EXPORT = qw(
      add_serial_console
      get_login_message
      download_file
      login
      prepare_serial_console
      serial_term_prompt
      upload_file
    );
    our @EXPORT_OK = qw(
      reboot
    );
}

our $serial_term_prompt;

=head2 add_serial_console

    add_serial_console($console);

Adds $console to /etc/securetty (unless already in file), enables systemd
service and start it. It requires selecting root console before.
=cut
sub add_serial_console {
    my ($console) = @_;
    my $service = 'serial-getty@' . $console;
    script_run(qq{grep -q "^$console\$" /etc/securetty || echo '$console' >> /etc/securetty}) if (is_sle('<12-sp2'));
    script_run("systemctl enable $service; systemctl start $service");
}

=head2 prepare_serial_console

    prepare_serial_console();

Wrapper for add_serial_console.
=cut

sub prepare_serial_console {
    # Configure serial consoles for virtio support
    # poo#18860 Enable console on hvc0 on SLES < 12-SP2
    # poo#44699 Enable console on hvc1 to fix login issues on ppc64le
    if (!check_var('VIRTIO_CONSOLE', 0)) {
        if (is_sle('<12-SP2') && !is_s390x) {
            add_serial_console('hvc0');
        }
        elsif (get_var('OFW')) {
            add_serial_console('hvc1');
        }
    }
}

=head2 get_login_message

   get_login_message();

Get login message printed by OS at the end of the boot.
Suitable for testing whether boot has been finished:

wait_serial(get_login_message(), 300);
=cut
sub get_login_message {
    my $arch = get_required_var("ARCH");
    return is_sle() ? qr/Welcome to SUSE Linux Enterprise .*\($arch\)/
      : is_sle_micro() ? qr/Welcome to SUSE Linux Enterprise Micro .*\($arch\)/
      : is_leap() ? qr/Welcome to openSUSE Leap.*/
      : qr/Welcome to openSUSE Tumbleweed 20.*/;
}

=head2 login

   login($user);

Enters root's name and password to login. Also sets the prompt to something static without ANSI
escape sequences (i.e. a single #) and changes the terminal width.

=cut
sub login {
    die 'Login expects two arguments' unless @_ == 2;
    my $user = shift;
    my $escseq = qr/(\e [\(\[] [\d\w]{1,2})/x;

    $serial_term_prompt = shift;

    bmwqemu::log_call;

    # Eat stale buffer contents, otherwise the code below may get confused
    # after reboot and start typing the username before the console is actually
    # ready to accept it
    wait_serial(qr/login:\s*$/i, timeout => 5, quiet => 1);
    # newline nudges the guest to display the login prompt, if this behaviour
    # changes then remove it
    send_key 'ret';
    die 'Failed to wait for login prompt' unless wait_serial(qr/login:\s*$/i);
    enter_cmd("$user");
    if (length $testapi::password) {
        die 'Failed to wait for password prompt' unless wait_serial(qr/Password:\s*$/i);
        type_password;
        send_key 'ret';
    }
    die 'Failed to confirm that login was successful' unless wait_serial(qr/$escseq* \w+:~\s\# $escseq* \s*$/x);
    # Some (older) versions of bash don't take changes to the terminal during runtime into account. Re-exec it.
    enter_cmd('export TERM=dumb; stty cols 2048; exec $SHELL');
    die 'Failed to confirm that shell re-exec was successful' unless wait_serial(qr/$escseq* \w+:~\s\# $escseq* \s*$/x);
    enter_cmd(qq/PS1="$serial_term_prompt"/);
    wait_serial(qr/PS1="$serial_term_prompt"/);
    # TODO: Send 'tput rmam' instead/also
    assert_script_run('export TERM=dumb');
    assert_script_run('echo Logged into $(tty)', timeout => $bmwqemu::default_timeout, result_title => 'vconsole_login');
}

sub serial_term_prompt {
    return $serial_term_prompt;
}

=head2 download_file

  download_file($src, $dst [, force => $force][, chunk_size => $cz][, chunk_retry => $cr])

Download a file from worker to SUT using the current serial terminal.
The file is split into chunks C<chunk_size> and each chunk is verified with
checksum. If a chunk fails, the upload will be retried up to C<chunk_retry>
times, before giving up.
To overwrite destination use C<force>.
This function die on any failure.
=cut
sub download_file {
    my ($src, $dst, %opts) = @_;
    $opts{chunk_size} //= 1024 * 2;
    $opts{chunk_retry} //= 16;
    $opts{force} //= 0;
    $opts{timeout} //= bmwqemu::scale_timeout(180);
    record_info('Download file', "From worker ($src) to SUT ($dst)");
    die("Relative path is forbidden - '$src'") if $src =~ m'/\.\.|\.\./';
    $src =~ s'^/+'';
    if ($src =~ m'data/') {
        $src = $bmwqemu::vars{CASEDIR} . '/' . $src;
    } else {
        $src = $bmwqemu::vars{ASSETDIR} . '/' . $src;
    }
    die("File $dst already exists on SUT") if (!$opts{force} && script_run("test -f $dst", quiet => 1, timeout => $opts{timeout}) == 0);
    die("File $src not found on worker") unless (-f $src);
    my $tmpdir = script_output('mktemp -d', quiet => 1, timeout => $opts{timeout});
    assert_script_run("test -d $tmpdir", quiet => 1);

    open(my $fh, '<:raw', $src) or die "Could not open file '$src' $!";
    my $result_file = $tmpdir . '/result';
    my $tmpfile = $tmpdir . '/chunk';
    my $cnt = 0;
    while (my $read = read($fh, my $chunk, $opts{chunk_size})) {
        my $b64 = b64_encode($chunk);
        my $tries = $opts{chunk_retry};
        my $sha1 = sha1_sum($b64);
        $cnt += 1;
        do {
            die("Failed to transfer chunk[$cnt] of file $src") if ($tries-- < 0);
            script_output("cat > $tmpfile << 'EOT'\n" . $b64 . "EOT", quiet => 1, timeout => $opts{timeout});
        } while ($sha1 ne script_output("sha1sum $tmpfile | cut -d ' ' -f 1", quiet => 1, timeout => $opts{timeout}));
        assert_script_run("base64 -d $tmpfile >> $result_file", quiet => 1, timeout => $opts{timeout});
        assert_script_run("rm $tmpfile", quiet => 1, timeout => $opts{timeout});
    }
    close($fh);
    my $sha1_remote = script_output("sha1sum $result_file | cut -d ' ' -f 1", quiet => 1, timeout => $opts{timeout});
    my $sha1 = sha1_sum(path($src)->slurp());
    die("Failed to transfer file $src - final checksum mismatch") if ($sha1_remote ne $sha1);
    assert_script_run("mv $result_file '$dst'", quiet => 1, timeout => $opts{timeout});
    assert_script_run("rmdir $tmpdir", quiet => 1, timeout => $opts{timeout});
}

=head2 upload_file
  upload_file($src, $dst, [, chunk_size => $cz][, chunk_retry => $cr]);

Upload a file from SUT to the worker using the current serial terminal.
The file is parted into chunks C<chunk_size> and each chunk gets is verified with
checksum. If a chunk fail we retry it C<chunk_retry> times, before give up.
The file is placed in the C<ulogs/> directory of the worker.

This function die on any failure.
=cut
sub upload_file {
    my ($src, $dst, %opts) = @_;
    my $chunk_size = $opts{chunk_size} //= 1024 * 2;
    $opts{chunk_retry} //= 16;
    $opts{timeout} //= bmwqemu::scale_timeout(180);
    record_info('Upload file', "From SUT($src) to worker ($dst)");

    $dst = basename($dst);
    $dst = "ulogs/" . $dst;
    my ($fh, $tmpfilename) = tempfile(UNLINK => 1, SUFFIX => '.openqa.upload');

    die("File $src does not exist on SUT") if (script_run("test -f $src", quiet => 1, timeout => $opts{timeout}) != 0);
    die("File $dst already exists on worker") if (-f $dst);

    my $filesize = script_output("stat --printf='%s' $src", quiet => 1, timeout => $opts{timeout});

    my $num_chunks = int(($filesize + $chunk_size - 1) / $chunk_size);
    for (my $i = 0; $i < $num_chunks; $i += 1) {
        my $tries = $opts{chunk_retry};
        my ($sha1_remote, $sha1, $b64);
        do {
            die("Failed to transfer chunk[$i] of file $src") if ($tries-- < 0);
            $b64 = script_output("dd if='$src' bs=$chunk_size skip=$i count=1 status=none | base64", quiet => 1, timeout => $opts{timeout});
            $sha1_remote = script_output("dd if='$src' bs=$chunk_size skip=$i count=1 status=none | base64 | sha1sum | cut -d ' ' -f 1", quiet => 1, timeout => $opts{timeout});
            # W/A: script_output skips the last newline
            $sha1 = sha1_sum($b64 . "\n");
        } while ($sha1 ne $sha1_remote);
        print $fh b64_decode($b64);
    }
    close($fh);
    my $sha1 = sha1_sum(path($tmpfilename)->slurp());
    my $sha1_remote = script_output("sha1sum $src | cut -d ' ' -f 1", quiet => 1, timeout => $opts{timeout});
    die("Failed to upload file $src - final checksum mismatch\nremote: $sha1_remote\ndestination:$sha1") if ($sha1_remote ne $sha1);
    system('mkdir -p ulogs/') == 0 or die('Failed to create ulogs/ directory');
    system(sprintf("cp '%s' '%s'", $tmpfilename, $dst)) == 0
      or die("Failed to finally copy file from '$tmpfilename' to '$dst'");
}


sub reboot {
    my (%args) = @_;
    $args{console} //= testapi::current_console;
    $args{reboot_cmd} //= 'systemctl reboot';
    $args{timeout} //= 300;
    my $check_file = '/dev/shm/openqa-reboot-check-' . random_string(8);

    bmwqemu::log_call(%args);
    die('Only root-virtio-terminal is supported') unless $args{console} eq 'root-virtio-terminal';

    assert_script_run("touch '$check_file'");

    record_info('REBOOT', "cmd: " . $args{reboot_cmd});
    script_run($args{reboot_cmd}, timeout => 0);
    reset_consoles;
    wait_serial('[lL]ogin:', timeout => $args{timeout});
    select_console($args{console});

    assert_script_run("! test -e '$check_file'");
}

1;
