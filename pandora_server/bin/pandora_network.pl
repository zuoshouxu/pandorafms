#!/usr/bin/perl
##########################################################################
# Pandora FMS Network Server
##########################################################################
# Copyright (c) 2006-2007 Sancho Lerena, slerena@gmail.com
#           (c) 2006-2007 Artica Soluciones Tecnologicas S.L
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 2
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
##########################################################################

# Includes list
use strict;
use warnings;

use Date::Manip;            # Needed to manipulate DateTime formats of input, output and compare
use Time::Local;            # DateTime basic manipulation
use Net::Ping;				# For ICMP latency
use Time::HiRes;			# For high precission timedate functions (Net::Ping)
use IO::Socket;				# For TCP/UDP access
use SNMP;					# For SNMP access (libsnmp-perl PACKAGE!)
use threads;

# Pandora Modules
use pandora_config;
use pandora_tools;
use pandora_db;

# FLUSH in each IO (only for debug, very slooow)
# ENABLED in DEBUGMODE
# DISABLE FOR PRODUCTION
$| = 0;

my %pa_config;

$SIG{'TERM'} = 'pandora_shutdown';
$SIG{'INT'} = 'pandora_shutdown';

# Inicio del bucle principal de programa
pandora_init(\%pa_config, "Pandora FMS Network Server");

# Read config file for Global variables
pandora_loadconfig (\%pa_config,1);

# Audit server starting
pandora_audit (\%pa_config, "Pandora FMS Network Daemon starting", "SYSTEM", "System");

print " [*] Starting up network threads\n";

if ( $pa_config{"daemon"} eq "1" ) {
	print " [*] Backgrounding Pandora FMS Network Server process.\n";
	&daemonize;
}

# Runs main program (have a infinite loop inside)
# 111 for ICMP PROC high latency (Interval > 100)
# 112 for ICMP PROC low latency (Interval < 100)
# 201 for TCP PROC high latency (Interval > 100)
# 202 for TCP PROC low latency (Interval < 100)
# 331 for SNMP DATA_INC high latency (interval > 100)
# 332 for SNMP DATA_INC low latency (interval < 100)
# 12 for ICMP DATA
# 32 for SNMP PROC
# 0 for the rest: TCP DATA, TCP DATA_INC and TCP DATA_STRING
#                 SNMP DATA, SNMP DATA_STRING
threads->new( \&pandora_network_subsystem, \%pa_config, 111);
threads->new( \&pandora_network_subsystem, \%pa_config, 112);
threads->new( \&pandora_network_subsystem, \%pa_config, 201);
threads->new( \&pandora_network_subsystem, \%pa_config, 202);
threads->new( \&pandora_network_subsystem, \%pa_config, 331);
threads->new( \&pandora_network_subsystem, \%pa_config, 332);
threads->new( \&pandora_network_subsystem, \%pa_config, 12);
threads->new( \&pandora_network_subsystem, \%pa_config, 32);
threads->new( \&pandora_network_subsystem, \%pa_config, 0);
print " [*] Threads loaded and running \n";
# Last thread is the main process

my $dbhost = $pa_config{'dbhost'};
my $dbname = $pa_config{'dbname'};
my $dbh = DBI->connect("DBI:mysql:$dbname:$dbhost:3306", $pa_config{'dbuser'}, $pa_config{'dbpass'}, { RaiseError => 1, AutoCommit => 1 });

while (1) {
	pandora_serverkeepaliver (\%pa_config, 1, $dbh);
	threads->yield;
	sleep ($pa_config{"server_threshold"});
}

#------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------
#---------------------  Main Perl Code below this line-----------------------
#------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------
#------------------------------------------------------------------------------------

########################################################################################
# pandora_shutdown ()
# Close system
########################################################################################
sub pandora_shutdown {
	logger (\%pa_config,"Pandora FMS Network Server Shutdown by signal ",0);
	print " [*] Shutting down Pandora FMS Network Server (received signal)...\n";
	exit;
}

##########################################################################
# SUB pandora_network_subsystem
# Subsystem to process network modules
# This module runs each X seconds (server threshold) checking for network modules status
##########################################################################

sub pandora_network_subsystem {
        # Init vars
	my $pa_config = $_[0];
	my $nettype = $_[1];
	# 111 for ICMP PROC high latency (Interval > 100)
	# 112 for ICMP PROC low latency (Interval < 100)
	# 201 for TCP PROC high latency (Interval > 100)
	# 202 for TCP PROC low latency (Interval < 100)
	# 331 for SNMP DATA_INC high latency (interval > 100)
	# 332 for SNMP DATA_INC low latency (interval < 100)
	# 12 for ICMP DATA
	# 32 for SNMP PROC
	# 0 for the rest: TCP DATA, TCP DATA_INC and TCP DATA_STRING
	#                 SNMP DATA, SNMP DATA_STRING
	my $nettypedesc;
	# Connect ONCE to Database, we pass DBI handler to all subprocess.
	my $dbh = DBI->connect("DBI:mysql:$pa_config->{'dbname'}:$pa_config->{'dbhost'}:3306", $pa_config->{'dbuser'}, $pa_config->{'dbpass'}, { RaiseError => 1, AutoCommit => 1 });

	my $id_agente;
	my $id_agente_modulo;
	my $id_tipo_modulo;
	my $max; my $min; my $module_interval;
	my $nombre; my $tcp_port; my $tcp_rcv; my $tcp_send; my $snmp_oid;
	my $snmp_community; my $ip_target; my $id_module_group;
	my $timestamp_old = 0; # Stores timestamp from tagente_estado table
	my $id_agente_estado; # ID from tagente_estado table
	my $estado_cambio; # store tagente_estado cambio field
	my $estado_estado; # Store tagente_estado estado field
	my $agent_name; # Agent name
	my $agent_interval; # Agent interval
	my $agent_disabled; # Contains disabled field of tagente
	my $agent_osdata; # Agent os data
	my $server_id; # My server id
	my $flag;
	my @sql_data2;
	my @sql_data;
	my @sql_data3;
	my $query_sql; my $query_sql2; my $query_sql3;
	my $exec_sql; my $exec_sql2;  my $exec_sql3;
	my $buffer;
	my $running; 

	$server_id = dame_server_id($pa_config, $pa_config->{'servername'}."_Net", $dbh);
	while ( 1 ) {
		logger ($pa_config,"Loop in Network Module Subsystem",10);
		# For each element
		# -read net type module (type 5, 6 or 7) or group cathegory 2
		# -read its last tagente_modulo table entry
		# -if tagente_estado + module_interval  timestamp<= present timestamp
		#     run module, sleep 15 secs. and continue
		#     if ok, store data and status
		# next element
		# Calculate ID Agent from a select where module_type (id_tipo_modulo) > 4 (network modules)
		# Check for MASTER SERVERS only: check another agents if their servers are gone
		$buffer = "";		
		if ($pa_config->{"pandora_master"} == 1){ 
			my $id_server;
			# I am the master, we need to check another agents
			# if their server is down
			# So look for servers down and keep their id_server
			$query_sql2 = "select * from tagente where disabled = 0 and id_server != $server_id";
			$exec_sql2 = $dbh->prepare($query_sql2);
			$exec_sql2 ->execute;
			while (@sql_data2 = $exec_sql2->fetchrow_array()) {
				$id_agente = $sql_data2[0];
				$id_server = $sql_data2[14];
				# Check if Network Server of that agent is down
				if (give_networkserver_status($pa_config, $id_server, $dbh) == 0) {
					# I'm the master server, and there is an agent
					# with its agent down, so ADD to list
					$buffer = $buffer." OR id_agente = $id_agente ";
					logger ($pa_config, "Added id_agente $id_agente for Master Network Server ".$pa_config->{"servername"}."_Net"." agent pool",10);
				}
			}
			$exec_sql2->finish();
		}	
		# First: Checkout for enabled agents owned by this server
		$query_sql2 = "SELECT * FROM tagente WHERE ( disabled = 0 AND id_server = $server_id ) ". $buffer;
		$exec_sql2 = $dbh->prepare($query_sql2);
		$exec_sql2 ->execute;
		while (@sql_data2 = $exec_sql2->fetchrow_array()) {
			$id_agente = $sql_data2[0];
			$agent_name = $sql_data2[1];
			$agent_interval = $sql_data2[7];
			$agent_disabled = $sql_data2[12];
			$agent_osdata =$sql_data2[8];
			
			# Second: Checkout for agent_modules with type = X
			# (network modules) and owned by our selected agent
			
			# 111 for ICMP PROC high latency (Interval > 100)
			# 112 for ICMP PROC low latency (Interval < 100)
			# 201 for TCP PROC high latency (Interval > 100)
			# 202 for TCP PROC low latency (Interval < 100)
			# 331 for SNMP DATA_INC high latency (interval > 100)
			# 332 for SNMP DATA_INC low latency (interval < 100)
			# 12 for ICMP DATA
			# 32 for SNMP PROC
			# 0 for the rest: TCP DATA, TCP DATA_INC and TCP DATA_STRING
			#                 SNMP DATA, SNMP DATA_STRING
			if ($nettype == 111){ # icmp proc high lat
				$query_sql = "select * from tagente_modulo where id_tipo_modulo = 6 AND (module_interval = 0 OR module_interval > 100) AND id_agente = $id_agente";
				$nettypedesc="ICMP PROC HighLatency";
			} elsif ($nettype == 112){ # icmp proc low lat
				$query_sql = "select * from tagente_modulo where id_tipo_modulo = 6 AND module_interval != 0 AND module_interval < 100 AND id_agente = $id_agente";
				$nettypedesc="ICMP PROC Low Latency";
			} elsif ($nettype == 201){ # tcp proc high lat
				$query_sql = "select * from tagente_modulo where id_tipo_modulo = 9 AND (module_interval = 0 OR module_interval > 100) AND id_agente = $id_agente";
				$nettypedesc="TCP PROC High Latency";
			} elsif ($nettype == 202){ # tcp proc low lat
				$query_sql = "select * from tagente_modulo where id_tipo_modulo = 9 AND module_interval != 0 AND module_interval < 100 AND id_agente = $id_agente";
				$nettypedesc="TCP PROC Low Latency";
			} elsif ($nettype == 331){ # SNMP DATA_INC high latency
				$query_sql = "select * from tagente_modulo where id_tipo_modulo = 16 AND ( module_interval = 0 OR module_interval > 100 ) AND id_agente = $id_agente";
				$nettypedesc="SNMP DataInc High Latency";
			} elsif ($nettype == 332){ # SNMP DATA_INC low latency
				$query_sql = "select * from tagente_modulo where id_tipo_modulo = 16 AND module_interval != 0 AND module_interval < 100 AND id_agente = $id_agente";
				$nettypedesc="SNMP DataInc Low Latency";
			} elsif ($nettype == 12){ #icmp data
				$query_sql = "select * from tagente_modulo where id_tipo_modulo = 7 AND id_agente = $id_agente";
				$nettypedesc="ICMP DATA (Latency)";
			} elsif ($nettype == 32){ #snmp proc
				$query_sql = "select * from tagente_modulo where id_tipo_modulo = 18 AND id_agente = $id_agente";
				$nettypedesc="SNMP PROC";
			} elsif ($nettype == 0){
			# TCP DATA, TCP DATA_INC and TCP DATA_STRING, UDP PROC
			# SNMP DATA, SNMP DATA_STRING
				$query_sql = "select * from tagente_modulo where ( id_tipo_modulo = 8 OR id_tipo_modulo = 10 OR id_tipo_modulo =11 OR id_tipo_modulo = 12 OR id_tipo_modulo = 15 OR id_tipo_modulo = 17 ) AND id_agente = $id_agente";
				$nettypedesc="TCPData, TCPDataInc, TCPString, SNMPData, SNMPString";
			}
			$exec_sql = $dbh->prepare($query_sql);
			$exec_sql ->execute; 
			while (@sql_data = $exec_sql->fetchrow_array()) {
				$id_agente_modulo = $sql_data[0];
				$id_agente= $sql_data[1];
				$id_tipo_modulo = $sql_data[2];
				$nombre = $sql_data[4];
				$min = $sql_data[6];
				$max = $sql_data[5];
				$module_interval = $sql_data[7];
				$tcp_port = $sql_data[8];
				$tcp_send = $sql_data[9];
				$tcp_rcv = $sql_data[10];
				$snmp_community = $sql_data[11];
				$snmp_oid = $sql_data[12];
				$ip_target = $sql_data[13];
				$id_module_group = $sql_data[14];
				$flag = $sql_data[15];
				if ($module_interval == 0) { 
					# If module interval not defined, get value for agent interval instead
					$module_interval = $agent_interval;
				}
				# Look for an entry in tagente_estado 
				$query_sql3 = "select * from tagente_estado where id_agente_modulo = $id_agente_modulo";
				$exec_sql3 = $dbh->prepare($query_sql3);
				$exec_sql3 ->execute;
				if ($exec_sql3->rows > 0) { # Exist entry in tagente_estado
					@sql_data3 = $exec_sql3->fetchrow_array();
					$timestamp_old = $sql_data3[8]; # Now use utimestamp
					$id_agente_estado = $sql_data3[0];
					$estado_cambio = $sql_data3[4];
					$estado_estado = $sql_data3[5];
					$running = $sql_data3[10];
				} else {
					$id_agente_estado = -1;
					$estado_estado = -1;
					$running = 0;
				}
				$exec_sql3->finish();
				# if timestamp of tagente_modulo + module_interval <= timestamp actual, exec module
				
				my $current_timestamp = &UnixDate("today","%s");
				my $err;
				my $limit1_timestamp = $timestamp_old + $module_interval;
				my $limit2_timestamp = $timestamp_old + ($module_interval*2);
				if (    ($limit2_timestamp < $current_timestamp) || 
					(($running == 0) && ( $limit1_timestamp < $current_timestamp)) || 
					($flag == 1) )  
				{ # Exec module, we are out time limit !
					if ($flag == 1){ # Reset flag to 0
						$query_sql3 = "UPDATE tagente_modulo SET flag=0 WHERE id_agente_modulo = $id_agente_modulo";
						$exec_sql3 = $dbh->prepare($query_sql3);
						$exec_sql3 ->execute;
						$exec_sql3->finish();
					}
					# Update running_by flag
					$query_sql3 = "UPDATE tagente_estado SET running_by = ".$pa_config->{'server_id'}." WHERE id_agente_modulo = $id_agente_modulo";
					$exec_sql3 = $dbh->prepare($query_sql3);
					$exec_sql3 ->execute;
					$exec_sql3->finish();
					logger ($pa_config, "Network Module Subsystem ($nettypedesc): Exec Netmodule '$nombre' ID $id_agente_modulo ",4);
					exec_network_module( $id_agente, $id_agente_estado, $id_tipo_modulo, $nombre, $min, $max, $agent_interval, $tcp_port, $tcp_send, $tcp_rcv, $snmp_community, $snmp_oid, $ip_target, $estado_cambio, $estado_estado, $agent_name, $agent_osdata, $id_agente_modulo, $pa_config, $dbh);
				} # Timelimit if
			} # while
			$exec_sql->finish();
		}	
		$exec_sql2->finish();
		threads->yield;
		sleep($pa_config->{"server_threshold"});
	}
	$dbh->disconnect();
}

##############################################################################
# pandora_ping_icmp (destination, timeout) - Do a ICMP scan, 1 if alive, 0 if not
##############################################################################
sub pandora_ping_icmp {
	my $dest = $_[0];
	my $l_timeout = $_[1];
	# temporal vars.
	my $result = 0;
	my $p;

	# Check for valid destination
	if (!defined($dest)) {
		return 0;
	}
	
	$p = Net::Ping->new("icmp",$l_timeout);
	$result = $p->ping($dest);
	
	# Check for valid result
	if (!defined($result)) {
		return 0;
	}
	
	# Lets see the result
	if ($result == 1) {
		$p->close();
		return 1;
	} else {
		$p->close();
		return 0;
	}
}

##########################################################################
# SUB pandora_query_tcp (pa_config, tcp_port. ip_target, result, data, tcp_send,
#						 tcp_rcv, id_tipo_module, dbh)
# Makes a call to TCP modules to get a value.
##########################################################################
sub pandora_query_tcp (%$$$$$$$$) {
	my $pa_config = $_[0];
	my $tcp_port = $_[1];
	my $ip_target = $_[2];
	my $module_result = $_[3];
	my $module_data = $_[4];
	my $tcp_send = $_[5];
	my $tcp_rcv = $_[6];
	my $id_tipo_modulo = $_[7];
	my $dbh = $_[8];
	
	my $temp; my $temp2;
	my $tam;

	my $handle=IO::Socket::INET->new(
		Proto=>"tcp",
		PeerAddr=>$ip_target,
		Timeout=>$pa_config->{'networktimeout'},
		PeerPort=>$tcp_port,
		Blocking=>0 ); # Non blocking !!, very important !
		
	if (defined($handle)){
		if ($tcp_send ne ""){ # its Expected to sending data ?
			# Send data
			$handle->autoflush(1);
			$tcp_send =~ s/\^M/\r\n/g;
			# Replace Carriage rerturn and line feed
			$handle->send($tcp_send);
		}
		# we expect to receive data ? (non proc types)
		if (($tcp_rcv ne "") || ($id_tipo_modulo == 10) || ($id_tipo_modulo ==8) || ($id_tipo_modulo == 11)) {
			# Receive data, non-blocking !!!! (VERY IMPORTANT!)
			$temp2 = "";
			for ($tam=0; $tam<($pa_config->{'networktimeout'}/2); $tam++){
				$handle->recv($temp,16000,0x40);
				$temp2 = $temp2.$temp;
				if ($temp ne ""){
					$tam++; # If doesnt receive data, increase counter
				}
				sleep(1);
			}
			if ($id_tipo_modulo == 9){ # only for TCP Proc
				if ($temp2 =~ /$tcp_rcv/i){ # String match !
					$$module_data = 1;
					$$module_result = 0;
				} else {
					$$module_data = 0;
					$$module_result = 0;
				}
			} elsif ($id_tipo_modulo == 10 ){ # TCP String (no int conversion)!
				$$module_data = $temp2;
				$$module_result =0;
			} else { # TCP Data numeric (inc or data)
				if ($temp2 ne ""){
					if ($temp2 =~ /[A-Za-z\.\,\-\/\\\(\)\[\]]/){
						$$module_result = 1;
						$$module_data = 0; # invalid data
					} else {
						$$module_data = int($temp2);
						$$module_result = 0; # Successful
					}
				} else {
						$$module_result = 1; 
                                                $$module_data = 0; # invalid data
					}
			}
		} else { # No expected data to receive, if connected and tcp_proc type successful
			if ($id_tipo_modulo == 9){ # TCP Proc
				$$module_result = 0;
				$$module_data = 1;
			}
		}
		$handle->close();
	} else { # Cannot connect (open sock failed)
		$$module_result = 1; # Fail
		if ($id_tipo_modulo == 9){ # TCP Proc
			$$module_result = 0;
			$$module_data = 0; # Failed, but data exists
		}
	}
}

##########################################################################
# SUB pandora_query_snmp (pa_config, oid, community, target, error, dbh)
# Makes a call to SNMP modules to get a value,
##########################################################################
sub pandora_query_snmp {
	my $pa_config = $_[0];
	my $snmp_oid = $_[1];
	my $snmp_community =$_[2];
	my $snmp_target = $_[3];
	# $_[4] contains error var.
	my $dbh = $_[5];
	my $output ="";
	$ENV{'MIBS'}="ALL";  #Load all available MIBs
	my $SESSION = new SNMP::Session (DestHost =>  $snmp_target,
                                Community => $snmp_community,
                                Version => 1);
   	if ((!defined($SESSION))&& ($snmp_community != "") && ($snmp_oid != "")) {
      		logger($pa_config, "SNMP ERROR SESSION for Target $snmp_target ", 4);
		$_[4] = "1";
   	} else {
		# Perl uses different OID syntax than SNMPWALK or PHP's SNMP
		# for example:
		# SNMPv2-MIB::sysDescr for PERL SNMP
		# is equivalent to SNMPv2-MIB::sysDescr.0 in SNMP and PHP/SNMP
		# So we parse last byte and cut off if = 0 and delete 1 if != 0
		my $perl_oid = $snmp_oid;
		if ($perl_oid =~ m/(.*)\.([0-9]*)\z/){
			my $local_oid = $1;
			my $local_oid_idx = $2;
			if ($local_oid_idx == 0){
				$perl_oid = $local_oid; # Strip .0 from orig. OID
			} else {
				$local_oid_idx--;
				$perl_oid = $local_oid.".".$local_oid_idx;
			}
		}
		my $OIDLIST =  new SNMP::VarList([$perl_oid]);
		# Pass the VarList to getnext building an array of the output
		my @OIDINFO = $SESSION->getnext($OIDLIST);
		$output = $OIDINFO[0];
		if ((!defined($output)) || ($output eq "")){
			$_[4] = "1";
			return 0;
		} else {
			$_[4] = "0";
		}
	}
	return $output;
}

##########################################################################
# SUB exec_network_module (many parameters...)
# Execute network module task in separated thread
##########################################################################
sub exec_network_module {
	my $id_agente = $_[0];
	my $id_agente_estado = $_[1];
	my $id_tipo_modulo= $_[2];
	my $nombre= $_[3];
	my $min= $_[4];
	my $max= $_[5];
	my $agent_interval= $_[6];
	my $tcp_port = $_[7];
	my $tcp_send = $_[8];
	my $tcp_rcv = $_[9];
	my $mysnmp_community = $_[10];
	my $mysnmp_oid = $_[11];
	my $ip_target = $_[12];
	my $estado_cambio = $_[13];
	my $estado_estado = $_[14];
	my $agent_name = $_[15];
	my $agent_osdata = $_[16];
	my $id_agente_modulo = $_[17];
	my $pa_config = $_[18];
	my $dbh = $_[19];

	
	my $error = "1";
	my $query_sql2;
	my $temp=0; my $tam; my $temp2;
	my $module_result = 1; # Fail by default
	my $module_data = 0;

	# ICMP Modules
	# ------------
	if ($id_tipo_modulo == 6){ # ICMP (Connectivity only: Boolean)
		$temp = pandora_ping_icmp ($ip_target, $pa_config->{'networktimeout'});
		if ($temp == 1 ){
			$module_result = 0; # Successful
			$module_data = 1;
		} else {
			$module_result = 0; # If cannot connect, its down.
			$module_data = 0;
		}
	} elsif ($id_tipo_modulo == 7){ # ICMP (data for latency in ms)
		# This module only could be executed if executed as root
		if ($> == 0){
			my $nm = Net::Ping->new("icmp");
			my $icmp_return;
			my $icmp_reply;
			my $icmp_ip;
			$nm->hires();
			($icmp_return, $icmp_reply, $icmp_ip) = $nm->ping ($ip_target,$pa_config->{"networktimeout"});
			if ($icmp_return) {
				$module_data = $icmp_reply * 1000; # milliseconds
				$module_result = 0; # Successful		
			} else {
				$module_result = 1; # Error.
				$module_data = 0;
			}
			$nm->close();
		} else {
			$module_result = 0; # Done but, with zero value
			$module_data = 0;
		}
	# SNMP Modules (Proc=18, inc, data, string)
	# ------------
	} elsif (($id_tipo_modulo == 15) || ($id_tipo_modulo == 18) || ($id_tipo_modulo == 16) || ($id_tipo_modulo == 17)) { # SNMP module
		if ($mysnmp_oid ne ""){
			$temp2 = pandora_query_snmp ($pa_config, $mysnmp_oid, $mysnmp_community, $ip_target, $error, $dbh);
		} else {
			 $error = 1
		}
		
		# SUB pandora_query_snmp (pa_config, oid, community, target, error, dbh)
		if ($error == 0) { # A correct SNMP Query
			$module_result = 0;
			# SNMP_DATA_PROC
			if ($id_tipo_modulo == 18){ #snmp_data_proc
				if ($temp2 != 1){ # up state is 1, down state in SNMP is 2 ....
					$temp2 = 0;
				}
				$module_data = $temp2;
				$module_result = 0; # Successful
			}
			# SNMP_DATA and SNMP_DATA_INC
			elsif (($id_tipo_modulo == 15) || ($id_tipo_modulo == 16) ){ 
				if ($temp2 =~ /[A-Za-z\.\,\-\/\\\(\)\[\]]/){
					$module_result = 1; # Alphanumeric data, not numeric
				} else {
					$module_data = int($temp2);
					$module_result = 0; # Successful
				} 
			} else { # String SNMP
				$module_data = $temp2;
				$module_result=0;
			}
		} else { # Failed SNMP-GET
			$module_data = 0;
			$module_result = 1; # No data, cannot connect
		}
	# TCP Module
	# ----------
	} elsif (($id_tipo_modulo == 8) || ($id_tipo_modulo == 9) || ($id_tipo_modulo == 10) || ($id_tipo_modulo == 11)) { # TCP Module
		if (($tcp_port < 65536) && ($tcp_port > 0)){ # Port check
			pandora_query_tcp ($pa_config, $tcp_port, $ip_target, \$module_result, \$module_data, $tcp_send, $tcp_rcv, $id_tipo_modulo, $dbh);
		} else { 
			$module_result = 1;
		}
   	}

	# --------------------------------------------------------
	# --------------------------------------------------------
	if ($module_result == 0) {
		my %part;
		$part{'name'}[0]=$nombre;
		$part{'description'}[0]="";
		$part{'data'}[0] = $module_data;
		$part{'max'}[0] = $max;
		$part{'min'}[0] = $min;
		my $timestamp = &UnixDate("today","%Y-%m-%d %H:%M:%S");
		my $tipo_modulo = dame_nombretipomodulo_idagentemodulo ($pa_config, $id_tipo_modulo, $dbh);
		if (($tipo_modulo eq 'remote_snmp') || ($tipo_modulo eq 'remote_icmp') || ($tipo_modulo eq 'remote_tcp') || ($tipo_modulo eq 'remote_udp'))  {
			module_generic_data ($pa_config, \%part, $timestamp, $agent_name, $tipo_modulo, $dbh);
		}
		elsif ($tipo_modulo =~ /\_inc/ ) {
			module_generic_data_inc ($pa_config, \%part, $timestamp, $agent_name, $tipo_modulo, $dbh);
		}
		elsif ($tipo_modulo =~ /\_string/) {
			module_generic_data_string ($pa_config, \%part, $timestamp, $agent_name, $tipo_modulo, $dbh);
		}
		elsif ($tipo_modulo =~ /\_proc/){
			module_generic_proc ($pa_config, \%part, $timestamp, $agent_name, $tipo_modulo, $dbh);
		}
		else {
			logger ($pa_config, "Problem with unknown module type '$tipo_modulo'", 0);
			goto skipdb_execmod;
		}
		# Update agent last contact
		# Insert Pandora version as agent version
		pandora_lastagentcontact ($pa_config, $timestamp, $agent_name,  $agent_osdata, $pa_config->{'version'}, $agent_interval, $dbh);
	} else { 
		# $module_result != 0)
		# Modules who cannot connect or something go bad, update last_try field
		logger ($pa_config, "Cannot obtain exec Network Module $nombre from agent $agent_name", 4);
		my $timestamp = &UnixDate("today","%Y-%m-%d %H:%M:%S");
		my $utimestamp = &UnixDate("today","%s");
		#my $query_act = "UPDATE tagente_estado SET utimestamp = $utimestamp, timestamp = '$timestamp', last_try = '$timestamp' WHERE id_agente_estado = $id_agente_estado ";
		my $query_act = "UPDATE tagente_estado SET last_try = '$timestamp' WHERE id_agente_estado = $id_agente_estado ";
		my $a_idages = $dbh->prepare($query_act);
		$a_idages->execute;
		$a_idages->finish();
	}
skipdb_execmod:
	#$dbh->disconnect();
}
