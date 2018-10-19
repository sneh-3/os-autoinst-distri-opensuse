# SUSE's openQA tests
#
# Copyright © 2018 SUSE LLC
#
# Copying and distribution of this file, with or without modification,
# are permitted in any medium without royalty provided the copyright
# notice and this notice are preserved.  This file is offered as-is,
# without any warranty.

# Summary: Advanced test cases for wicked
# Test 7 : Create a tun interface from legacy ifcfg files
# Maintainer: Anton Smorodskyi <asmorodskyi@suse.com>
#             Jose Lausuch <jalausuch@suse.com>
#             Clemens Famulla-Conrad <cfamullaconrad@suse.de>

use base 'wickedbase';
use strict;
use testapi;
use utils 'systemctl';
use lockapi;
use mmapi;

sub run {
    my ($self)         = @_;
    my $config         = '/etc/sysconfig/network/ifcfg-tun1';
    my $openvpn_server = '/etc/openvpn/server.conf';
    record_info('Info', 'Create a TUN interface from legacy ifcfg files');
    $self->get_from_data('wicked/ifcfg/tun1_ref',      $config);
    $self->get_from_data('wicked/openvpn/server.conf', $openvpn_server);
    assert_script_run("sed 's/device/tun1/' -i $openvpn_server");
    $self->setup_tuntap($config, 'tun1', 1);
    mutex_wait('test_tun_interface_legacy_ready');
}

sub test_flags {
    return {always_rollback => 1};
}

1;
