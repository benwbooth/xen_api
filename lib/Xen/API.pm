=head1 NAME

Xen::API Perl interface to the Xen RPC-XML API.

=head1 SYNOPSIS

  use Xen::API;
  my $x = Xen::API->new;

  my %vms = $x->list_vms
  my %templates = $x->list_templates

  my $vm = $x->create_vm(template=>'my_template',cpu=>4,memory=>'16G',vmname=>'this_vm');

  my $vm_records = $x->Xen::API::VM::get_all_records();

=head1 DESCRIPTION

Perl interface to the Xen RPC-XML API. Contains some shortcuts for creating, 
destroying, importing, and exporting VMs. All RPC API commands are available in
the Xen::API:: package space. Simply replace the dots with :: and prepend 
Xen::API:: to the command, and execute it as if it were a perl function. Be 
sure to pass the Xen object as the first parameter.

=head1 METHODS

=cut

package Xen::API;
use RPC::XML;
$RPC::XML::FORCE_STRING_ENCODING = 1;
use RPC::XML::Client;
use IO::Prompt ();
use Net::OpenSSH;
use URI;
use URI::QueryParam;
use HTTP::Request;
use Net::HTTP;
use HTTP::Status qw(:constants);
use Number::Format qw(:subs);
use FileHandle;
use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);

our @EXPORT_OK=qw(bool true false string Int i4 i8 double datetime
                nil base64 array struct fault prompt mem xen run);
our %EXPORT_TAGS=(all=>\@EXPORT_OK);
our $PACKAGE_PREFIX = __PACKAGE__;

our $VERSION = '0.06';

=head2 prompt

Display a password prompt.

=cut

sub prompt {
  my $message = shift || 'Enter password: ';
  IO::Prompt::prompt($message, -e=>'', '-tty').'';
}

=head2 mem

Convert suffix notation (k, M, G) to byte count. Useful for writing memory to give
to VM.

=cut

sub mem { unformat_number(@_) }

=head2 bool true false string Int i4 i8 double datetime nil base64 array struct fault

shortcuts for RPC::XML explicit typecasts

=cut

sub bool { RPC::XML::boolean->new(@_) }
sub true { RPC::XML::boolean->new(1) }
sub false { RPC::XML::boolean->new(0) }
sub string { RPC::XML::string->new(@_) }
sub Int { RPC::XML::int->new(@_) }
sub i4 { RPC::XML::i4->new(@_) }
sub i8 { RPC::XML::i8->new(@_) }
sub double { RPC::XML::double->new(@_) }
sub datetime { RPC::XML::datetime_iso8601->new(@_) }
sub nil { RPC::XML::nil->new(@_) }
sub base64 { RPC::XML::base64->new(@_) }
sub array { RPC::XML::array->new(@_) }
sub struct { RPC::XML::struct->new(@_) }
sub fault { RPC::XML::fault->new(@_) }

=head2 xen

Create a new instance of a Xen class.

=cut

sub xen {Xen::API->new(@_)}

=head2 new($uri, $user, $password)

New Xen instance. 

=cut

sub new {
  my $class = shift or return;
  my $uri = shift or return;
  my $user = shift || 'root';
  my $password = shift;

  my $self = {};
  bless $self, $class;

  $uri = "http://$uri" if !URI->new($uri)->scheme;
  $self->{host} = URI->new($uri)->host;
  $self->{uri} = $uri;
  $self->{xen} = RPC::XML::Client->new($self->{uri});

  # set up autoload packages for Xen API.
  my %seen;
  my %classes = 
    map {(
      __PACKAGE__."::$_"=>__PACKAGE__,
      $PACKAGE_PREFIX? ("${PACKAGE_PREFIX}::$_"=>$PACKAGE_PREFIX) : ($_=>undef), 
    )}
    map {s/\.[^.]*$//; s/\./::/g; !$seen{$_}++?$_:()} 
    @{$self->{xen}->simple_request('system.listMethods')||[]};
  for my $c (keys %classes) {
    my $package = $classes{$c};
    my $eval = <<EOS;
      package $c; 
      no warnings 'redefine'; 
      our \$AUTOLOAD; 
      sub AUTOLOAD {
        my \$self = shift;
        \$AUTOLOAD=~s/^\\Q\${package}::\\E// if defined \$package;
        \$AUTOLOAD=~s/::/./g; 
        \$self->request(\$AUTOLOAD,\@_);
      };
EOS
    eval $eval;
  }

  # login
  $self->{user} = $user;
  $password = prompt("Enter xen admin password for ".$self->{uri}.": ") 
    if !defined($password);
  $self->{session} = $self->value(
    $self->{xen}->simple_request('session.login_with_password',$user,$password));
  return $self;
}

=head2 create_vm

Create a new VM. 

Arguments:
    - vmname - The xen name of the VM.
    - template - The template to base the VM from.
    - cpu - How many CPUs to assign
    - memory - How much memory to assign

Returns a ref to the newly created VM.

=cut

sub create_vm {
  my $self = shift or return;

  # read arguments
  my %args = @_;
  my $vmname = $args{vmname};
  my $template = $args{template};
  die "No template name given" if !defined $template;
  my $cpu=$args{cpu};
  my $memory=$args{memory};
  die "No VM name given" if !defined $vmname;

  # get the list of VMs and templates in this pool
  my %vms = %{$self->Xen::API::VM::get_all_records||{}};
  my @templates = grep {$vms{$_}{is_a_template} && @{$vms{$_}{VBDs}||[]}} keys %vms;

  # query for the template by name or uuid
  my @use_template = grep {
    $vms{$_}{name_label} eq $template
      || $vms{$_}{uuid} eq $template
      || $_ eq $template} @templates;
  die "No template named \"$template\"!\n" if !@use_template;
  die "Multiple templates found matching \"$template\":\n"
    .join(', ',map {"\"$vms{$_}{name_label}\" ($vms{$_}{uuid})"} @use_template) 
    if @use_template>1;
  my $use_template = $use_template[0];

  # clone the template into a new VM
  my $new_vm = $self->Xen::API::VM::clone($use_template,$vmname);

  # set number of VCPUs
  if (defined($cpu)) {
    $self->Xen::API::VM::set_VCPUs_max($new_vm,$cpu);
    $self->Xen::API::VM::set_VCPUs_at_startup($new_vm,$cpu);
  }

  # set memory. There seem to be two mutually incompatible APIs: One used by
  # XenAPI 6.1, and another for earlier XenAPI versions. Try both, and
  # hopefully one of them will succeed.
  if (defined($memory)) {
    my $mem = unformat_number($memory);

    # new API, try this first
    my @err;
    eval {
      $self->Xen::API::VM::set_memory_limits($new_vm,$mem,$mem,$mem,$mem);
    };
    if ($@) {
      push @err, $@;
      # try the old API if the new API call fails
      eval {
        $self->Xen::API::VM::set_memory_dynamic_min($new_vm,$mem);
        $self->Xen::API::VM::set_memory_dynamic_max($new_vm,$mem);
        $self->Xen::API::VM::set_memory_static_min($new_vm,$mem);
        $self->Xen::API::VM::set_memory_static_max($new_vm,$mem);
      };
      if ($@) {
        push @err, $@;
        die "Could not set memory for $vmname: \n".join("\n",@err);
      }
    }
  }

  # provision the VM
  $self->Xen::API::VM::provision($new_vm);

  # start the VM
  $self->Xen::API::VM::start($new_vm,false,true); 

  my $ip = $self->get_ip($new_vm);
  print STDERR "IP address for $vmname: $ip\n";
  return $new_vm;
}

=head2 script

Run a remote script on a VM guest over SSH.

Arguments:
    - script - Remote script file to run on the guest via SSH
    - vmname - Name of the VM where the script should be run
    - user - SSH user name for running a remote command on the guest
    - password - SSH password for running a remote command on the guest
    - port - SSH port for running a remote command on the guest
    - sudo - Should sudo be used to run a remote command on the guest?

=cut

BEGIN {
  my $lastpassword;
  sub script {
    my $self = shift or return;
    my %args = @_;
    my $vmname = $args{vmname} or return;
    my $script = $args{script};
    my $command = $args{command};
    my $user = $args{user};
    my $port = $args{port};
    my $sudo = $args{sudo};
    my $password = exists($args{password})?$args{password}:$lastpassword;
    die "No command or script was given" if !defined($command) && !defined($script);

    # find the VM
    my %vms = %{$self->Xen::API::VM::get_all_records||{}};
    my @vms = grep {$vms{$_}{name_label} eq $vmname
        || $vms{$_}{uuid} eq $vmname
        || $_ eq $vmname} keys %vms;
    die "Multiple VMs matched $vmname" if @vms > 1;
    my $vm = $vms[0] or die "Could not find vm $vmname";
    die "VM $vmname is not running" if ($vms{$vm}{power_state}||'') ne 'Running';

    # prompt for password
    if ((exists($args{password}) || $sudo) && !defined($password)) {
      $password = prompt("Enter login password: ");
    }
    $lastpassword = $password;

    my $ip = $self->get_ip($vm)
      or die "Could not determine IP address of $vmname";

    # read the contents of the file to a string
    if (defined($script) && !defined($command)) {
      die "Could not read script file $script" if !-r $script;
      $command = do {local(@ARGV, $/) = $script; <>};
    }

    # Run the remote command using SSH.
    my $ssh = Net::OpenSSH->new($ip, 
      defined($user)?(user=>$user):(), 
      defined($password)?(password=>$password):(),
      defined($port)?(port=>$port):(),
      master_opts=>[-o=>'StrictHostKeyChecking=no'],
    );
    die "Couldn't establish SSH connection: ".$ssh->error if $ssh->error;
    if ($sudo) {
      $ssh->system({stdin_data=>"$password\n$command"},
        'sudo -Sk -p "" -- "$SHELL"');
    }
    else {
      $ssh->system({stdin_data=>$command}, '"$SHELL"');
    }
  }
}

=head2 get_ip

Gets the IP address of a VM.

=cut

sub get_ip {
  my $self = shift or return;
  my $vmname = shift or return;
  my $maxwait = shift;
  $maxwait = 60 if !defined($maxwait);

  my %vms = %{$self->Xen::API::VM::get_all_records||{}};
  my @vms = grep {
    $vms{$_}{name_label} eq $vmname
      || $vms{$_}{uuid} eq $vmname
      || $_ eq $vmname} keys %vms;
  my $vm = $vms[0] or die "Could not find vm $vmname";
  my $ip = $self->_get_ip($vm, $maxwait)
    or die "Could not get IP address of VM $vmname: timeout";
  return $ip;
}

sub _get_ip {
  my $self = shift or return;
  my $vm = shift or return;
  my $maxwait = shift;
  $maxwait=60 if !defined $maxwait;

  # get the IP address of the VM
  my $wait=0;
  my $ip;
  while (!$ip && $wait < $maxwait) {
    eval {
      my $vgm = $self->Xen::API::VM::get_guest_metrics($vm);
      my $net = $self->Xen::API::VM_guest_metrics::get_networks($vgm);
      $ip = $net->{'0/ip'} if $net;
    };
    $wait++;
    sleep 1 if !$ip && $wait < $maxwait;
  }
  return $ip;
}

=head2 destroy_vm

Destroys a VM and its associated VDIs.

=cut

sub destroy_vm {
  my $self = shift or return;
  my $vmname = shift or return;

  # find the VM
  my %vms = %{$self->Xen::API::VM::get_all_records||{}};
  my @vms = grep {
    $vms{$_}{name_label} eq $vmname
      || $vms{$_}{uuid} eq $vmname
      || $_ eq $vmname} keys %vms;
  die "Multiple VMs matched $vmname" if @vms > 1;
  my $vm = $vms[0] or die "Could not find vm $vmname";

  # make sure the VM is shut down
  if (($vms{$vm}{power_state}||'') ne 'Halted') {
    $self->Xen::API::VM::hard_shutdown($vm);
  }

  # destroy the attached VDIs
  for my $vbd (@{$vms{$vm}{VBDs}||[]}) {
    my $vbd_record = $self->Xen::API::VBD::get_record($vbd);
    $self->Xen::API::VDI::destroy($vbd_record->{VDI})
      if $vbd_record->{VDI} 
        && $vbd_record->{VDI} ne 'OpaqueRef:NULL'
        && $vbd_record->{type} ne 'CD';
  }

  #destroy the VM
  $self->Xen::API::VM::destroy($vm);
  return '';
}

=head2 import_vm

Import a VM from a xva file.

=cut

sub import_vm {
  my $self = shift or return;
  my $filename = shift or return;
  my $sr_id = shift;

  # find the storage repository if specified
  my $sr_uuid;
  if ($sr_id) {
    my %sr = %{$self->Xen::API::SR::get_all_records||{}};
    my @srs = grep {
      $sr{$_}{name_label} eq $sr_id
        || $sr{$_}{uuid} eq $sr_id
        || $_ eq $sr_id} keys %sr;
    my $sr = $srs[0]
      or die "Could not find storage repository $sr_id";
    $sr_uuid = $sr{$sr}{uuid};
  }

  # create the source and destination tasks
  my $task = $self->Xen::API::task::create("import_$filename","Import VM $filename");

  eval {
    # URI
    my $uri = URI->new($self->{uri});
    $uri->path('import');
    $uri->query_param(session_id=>$self->{session});
    $uri->query_param(task_id=>$task);
    $uri->query_param(sr_uuid=>$sr_uuid) if $sr_uuid;

    my $import = Net::HTTP->new(Host=>$uri->host_port)
      or die "Could not connect to host at ".$uri->host_port.": $@";
    $import->write_request(
      PUT=>$uri->path_query,
      'User-Agent'=>'perl-Xen-API');

    my $fh = FileHandle->new($filename, 'r')
      or die "Could not open $filename for reading: $!";
    $fh->binmode;
    $import->print($_) while <$fh>;
    $fh->close;

    # check HTTP status code
    my ($code, $message, %headers) = $import->read_response_headers;
    die "import returned HTTP Status code: $code" if $code != HTTP_OK;
  };

  my $task_record = $self->Xen::API::task::get_record($task);

  # Wait for the task status to be updated
  my $wait=0;
  my $maxwait=60;
  while ($task_record && ($task_record->{status}||'') eq 'pending'
           && $wait < $maxwait)
  {
    $task_record = $self->Xen::API::task::get_record($task);
    sleep 1;
    $wait++;
  }

  $self->Xen::API::task::destroy($task);

  die $@ if $@;
  die "Import task returned status $task_record->{status}: "
    .join(', ',@{$task_record->{error_info}||[]})
      if $task_record->{status} ne 'success';
  return '';
}

=head2 export_vm

Export a VM to a xva file.

=cut

sub export_vm {
  my $self = shift or return;
  my $vmname = shift or return;
  my $filename = shift or return;

  # find the VM
  my %vms = %{$self->Xen::API::VM::get_all_records||{}};
  my @vms = grep {
    $vms{$_}{name_label} eq $vmname
      || $vms{$_}{uuid} eq $vmname
      || $_ eq $vmname} keys %vms;
  my $vm = $vms[0] or die "Could not find vm $vmname";

  my $task = $self->Xen::API::task::create("export_$vm","Export VM $vm");

  # URI
  my $uri = URI->new($self->{uri});
  $uri->path('export');
  $uri->query_param(session_id=>$self->{session});
  $uri->query_param(task_id=>$task);
  $uri->query_param(ref=>$vm);

  eval {
    # export socket connection
    my $export = Net::HTTP->new(Host=>$uri->host_port)
      or die "Could not connect to host at ".$uri->host_port.": $@";
    $export->write_request(
      GET=>$uri->path_query,
      'User-Agent'=>'perl-Xen-API');

    # check HTTP status code
    my ($code, $message, %headers) = $export->read_response_headers;
    die "import returned HTTP Status code: $code" if $code != HTTP_OK;

    my $fh = FileHandle->new($filename, 'w')
      or die "Could not open $filename for writing: $!";
    $fh->binmode;
    $fh->print($_) while <$export>;
    $fh->close;
  };
  
  my $task_record = $self->Xen::API::task::get_record($task);

  # Wait for the task status to be updated
  my $wait=0;
  my $maxwait=60;
  while ($task_record && ($task_record->{status}||'') eq 'pending'
           && $wait < $maxwait)
  {
    $task_record = $self->Xen::API::task::get_record($task);
    sleep 1;
    $wait++;
  }
  $self->Xen::API::task::destroy($task);

  die $@ if $@;
  die "Export task returned status $task_record->{status}: "
    .join(', ',@{$task_record->{error_info}||[]})
      if $task_record->{status} ne 'success';
  return '';
}


=head2 transfer_vm

Transfer a VM from one xen server to another without creating an intermediate file.

=cut

sub transfer_vm {
  my $self = shift or return;
  my $vmname = shift or return;
  my $dest_xen = shift or return;
  my $sr_id = shift;

  # find the VM
  my %vms = %{$self->Xen::API::VM::get_all_records||{}};
  my @vms = grep {
    $vms{$_}{name_label} eq $vmname
      || $vms{$_}{uuid} eq $vmname
      || $_ eq $vmname} keys %vms;
  my $vm = $vms[0] or die "Could not find vm $vmname";

  # find the storage repository if specified
  my $sr_uuid;
  if ($sr_id) {
    my %sr = %{$dest_xen->Xen::API::SR::get_all_records||{}};
    my @srs = grep {
      $sr{$_}{name_label} eq $sr_id
        || $sr{$_}{uuid} eq $sr_id
        || $_ eq $sr_id} keys %sr;
    my $sr = $srs[0]
      or die "Could not find storage repository $sr_id";
    $sr_uuid = $sr{$sr}{uuid};
  }

  # export task
  my $export_task = $self->Xen::API::task::create("export_$vm","Export VM $vm");
  # import task
  my $import_task = $dest_xen->Xen::API::task::create("import_$vm","Import VM $vm");

  eval {
    # export URI
    my $export_uri = URI->new($self->{uri});
    $export_uri->path('export');
    $export_uri->query_param(session_id=>$self->{session});
    $export_uri->query_param(task_id=>$export_task);
    $export_uri->query_param(ref=>$vm);
    
    # export socket connection
    my $export = Net::HTTP->new(Host=>$export_uri->host_port)
      or die "Could not connect to host at ".$export_uri->host_port.": $@";
    $export->write_request(
      GET=>$export_uri->path_query,
      'User-Agent'=>'perl-Xen-API');
    { my ($code, $message, %headers) = $export->read_response_headers;
      die "export returned HTTP Status code: $code" if $code != HTTP_OK;
    }

    # import URI
    my $import_uri = URI->new($dest_xen->{uri});
    $import_uri->path('import');
    $import_uri->query_param(session_id=>$dest_xen->{session});
    $import_uri->query_param(task_id=>$import_task);
    $import_uri->query_param(sr_uuid=>$sr_uuid) if $sr_uuid;
    
    # import socket connection
    my $import = Net::HTTP->new(Host=>$import_uri->host_port)
      or die "Could not connect to host at ".$import_uri->host_port.": $@";
    $import->write_request(
      PUT=>$import_uri->path_query,
      'User-Agent'=>'perl-Xen-API');

    # transfer the VM
    $import->print($_) while <$export>;

    { my ($code, $message, %headers) = $export->read_response_headers;
      die "export returned HTTP Status code: $code" if $code != HTTP_OK;
    }
  };

  # get task statuses
  my $export_task_record = $self->Xen::API::task::get_record($export_task);
  my $import_task_record = $dest_xen->Xen::API::task::get_record($import_task);

  # Wait for the task statuses to be updated
  my $wait=0;
  my $maxwait=60;
  while ((($export_task_record && ($export_task_record->{status}||'') eq 'pending')
       || ($import_task_record && ($import_task_record->{status}||'') eq 'pending'))
    && $wait < $maxwait)
  {
    $export_task_record = $self->Xen::API::task::get_record($export_task);
    $import_task_record = $dest_xen->Xen::API::task::get_record($import_task);
    sleep 1;
    $wait++;
  }

  # remove task statuses
  $self->Xen::API::task::destroy($export_task);
  $dest_xen->Xen::API::task::destroy($import_task);

  # error handling
  my @errors;
  push @errors, $@ if $@;
  push @errors, "Import task returned status $import_task_record->{status}: "
    .join(', ',@{$import_task_record->{error_info}||[]})
      if $import_task_record->{status} ne 'success';
  push @errors, "Export task returned status $export_task_record->{status}: "
    .join(', ',@{$export_task_record->{error_info}||[]})
      if $export_task_record->{status} ne 'success';
  die join("\n",@errors) if @errors;

  return '';
}

=head2 set_template

Set the is_a_template flag for a VM.

=cut

sub set_template {
  my $self = shift or return;
  my $vmname = shift or return;
  my $set_template = shift;
  $set_template = 1 if !defined($set_template);
  
  # find the VM
  my %vms = %{$self->Xen::API::VM::get_all_records||{}};
  my @vms = grep {
    $vms{$_}{name_label} eq $vmname
      || $vms{$_}{uuid} eq $vmname
      || $_ eq $vmname} keys %vms;
  my $vm = $vms[0] or die "Could not find vm $vmname";

  $self->Xen::API::VM::set_is_a_template(
    $vm,
    $set_template?
      ref($set_template)? $set_template : true
    : false);
  return '';
}

=head2 list_vms

List the VMs on this Xen server.

=cut
 
sub list_vms {
  my $self = shift or return;
  my %vms = %{$self->Xen::API::VM::get_all_records||{}};
  my @vms = grep {!$vms{$_}{is_a_template}} keys %vms;
  return map {{
      name_label=>$vms{$_}{name_label},
      uuid=>$vms{$_}{uuid},
      ref=>$_,
      power_state=>$vms{$_}{power_state},
      ip=>($vms{$_}{power_state}||'') eq 'Running' ? $self->_get_ip($_,1) : undef,
    }}
    sort {$vms{$a}{name_label} cmp $vms{$b}{name_label}} @vms;
}

=head2 list_templates

List the templates on this Xen server.

=cut

sub list_templates {
  my $self = shift or return;
  my $vbds_only = shift;
  my %vms = %{$self->Xen::API::VM::get_all_records||{}};
  my @templates = grep {$vms{$_}{is_a_template} && (!$vbds_only || @{$vms{$_}{VBDs}||[]})} keys %vms;
  return map {{
    name_label=>$vms{$_}{name_label},
    uuid=>$vms{$_}{uuid},
    ref=>$_,
  }}
    sort {$vms{$a}{name_label} cmp $vms{$b}{name_label}} @templates;
}

=head2 list_hosts

List the physical hosts and related information.

=cut

sub list_hosts {
  my $self = shift or return;
  my %hosts = %{$self->Xen::API::host::get_all_records||{}};
  my %cpus = %{$self->Xen::API::host_cpu::get_all_records||{}};
  my %metrics = map {$_=>$self->Xen::API::host_metrics::get_record($hosts{$_}{metrics})} keys %hosts;

  return map {{
    name_label=>$hosts{$_}{name_label},
    uuid=>$hosts{$_}{uuid},
    ref=>$_,
    cpus=>scalar(@{$hosts{$_}{host_CPUs}||[]}),
    %{$metrics{$_}},
    memory_free=>format_bytes($metrics{$_}{memory_free}, mode=>'iec'),
    memory_total=>format_bytes($metrics{$_}{memory_total}, mode=>'iec'),
  }} sort {$hosts{$a}{name_label} cmp $hosts{$b}{name_labe}} keys %hosts;
}

sub value {
  my $self = shift or return;
  my ($val) = @_;
  return $val && ($val->{Status}||'') eq "Success"
    ? $val->{Value} 
    : die "Received status \"$val->{Status}\" from xen server at ".$self->{uri}.": "
      .join(', ',@{$val->{ErrorDescription}||[]});
}

sub request {
  my $self = shift or return;
  my $request = shift or return;
  return $self->value($self->{xen}->simple_request($request, $self->{session}, @_));
}

1;

=head1 AUTHOR

Ben Booth, benwbooth@gmail.com

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2013 by Ben Booth

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.1 or,
at your option, any later version of Perl 5 you may have available.


=cut

