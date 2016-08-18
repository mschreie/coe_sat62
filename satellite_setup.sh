#!/bin/bash
# satellite_setup.sh
# mschreie@redhat.com
# setting up  a satellite for demo purposes 
# mainly following Adrian Bredshaws awsome book: http://gsw-hammer.documentation.rocks/
# up to now this script has a very narrow prerequisits
# it is meant to work exactly for my demo server
# maybe it's a starting point for a more flexible script
# perhaps it would be better to go for the REST API with that.....

# http://gsw-hammer.documentation.rocks/content_views/defining_content_views.html


logfile=$(basename $0 .sh).log
donefile=$(basename $0 .sh).done
touch $logfile
touch $donefile


exec > >(tee -a "$logfile") 2>&1

echo "###INFO: Starting $0"
echo "###INFO: $(date)"

# read configuration (needs to be adopted!)
. ./satenv.sh


doit() {
	echo "INFO: doit: $@" >&2
	cmd2grep=$(echo "$*" | sed -e 's/\\//' | tr '\n' ' ')
	grep -q "$cmd2grep" $donefile 
	if [ $? -eq 0 ] ; then
		echo "INFO: doit: found cmd in donefile - skipping" >&2
	else
		"$@" 2>&1 || {
			echo "ERROR: cmd was unsuccessfull RC: $? - bailing out" >&2
			exit 1
		}
		echo "$cmd2grep" >> $donefile
		echo "INFO: doit: cmd finished successfull" >&2
	fi
}

# get /etc/hosts right
doit sed -is '$a\
'"$MYIP	$MYNAME" /etc/hosts


doit satellite-installer --scenario satellite --foreman-proxy-dhcp true --foreman-proxy-dhcp-interface eth1 --foreman-proxy-dhcp-range "$RANGEFROM $RANGETO" --foreman-proxy-dhcp-nameservers "$DNSSERVER" --foreman-proxy-dns true --foreman-proxy-dns-forwarders "$DNSFORWARDERS" --foreman-proxy-dns-interface $SATINTERFACE --foreman-proxy-dns-zone "$DNSDOMAIN" --foreman-proxy-dns-reverse "$DNSREVERSDOM" --foreman-proxy-tftp true --katello-proxy-url=http://proxy.coe.muc.redhat.com --katello-proxy-port=3128 --enable-foreman-plugin-openscap --enable-foreman-proxy-plugin-openscap

mkdir -p /root/.hammer 2>/dev/null
hammercredentials=$(foreman-rake permissions:reset | awk ' { print $NF } ' ; test ${PIPESTATUS[0]} -eq 0)

cat >/root/.hammer/cli_config.yml <<EOF
:foreman:
 :host: 'https://localhost'
 :username: 'admin'
 :password: '$hammercredentials'
EOF

hname=$(echo "${MYNAME}." | sed -e 's/\.\././g')
hrevname=$(echo "${MYREVERSENAME}." | sed -e 's/\.\././g')
cat <<EOF
INFO: do: nsupdate -l -k /etc/rndc.key <<EOF
INFO: update add $hname 3600 A $MYIP
INFO: send
INFO: update add $hrevname  3600 PTR $hname
INFO: send
INFO: EOF
EOF

nsupdate -l -k /etc/rndc.key <<EOF  
update add $hname 3600 A $MYIP
send
update add $hrevname  3600 PTR $hname
send
EOF
if [ $? -ne 0 ] ; then  
	echo "ERROR: cmd was unsuccessfull RC: $? - bailing out" >&2
	exit 1
fi

doit yum install puppet-foreman_scap_client -y
 
echo "INFO: changeing /etc/resolv.conf"
cat <<EOF >/etc/resolv.conf
#
# resolver configuration file...
#
options         timeout:1 attempts:8 rotate
domain          example.com
search          example.com
 
nameserver 127.0.0.1
EOF
cat /etc/resolv.conf


doit hammer organization create  --name "${ORG}"
doit hammer location create --name "${LOC}"

# doit hammer subscription upload --organization "${ORG}" --file  /root/manifest_fdb1909e-da83-4d5e-9d5b-f717d157c16e.zip
doit wget http://file.rdu.redhat.com/~rjerrido/manifests/Satellite_61_Generated_27_Jul_2016.zip
doit hammer subscription upload --organization "${ORG}" --file  /root/Satellite_61_Generated_27_Jul_2016.zip

doit hammer repository-set enable  --organization "${ORG}" --product "Red Hat Enterprise Linux Server" \
	 --name "Red Hat Enterprise Linux 7 Server (Kickstart)" --releasever "7.2" --basearch "x86_64"

doit hammer repository-set enable  --organization "${ORG}"  --product "Red Hat Enterprise Linux Server" \
	 --name "Red Hat Enterprise Linux 7 Server (RPMs)" --releasever "7Server" --basearch "x86_64"

doit hammer repository-set enable  --organization "${ORG}"   --product "Red Hat Enterprise Linux Server"  \
	 --name "Red Hat Satellite Tools 6.2 (for RHEL 7 Server) (RPMs)" --basearch "x86_64"

doit hammer repository-set enable  --organization "${ORG}" --product "Red Hat Enterprise Linux Server" \
	 --name "Red Hat Enterprise Linux 7 Server - RH Common (RPMs)" --releasever "7Server" --basearch "x86_64"

doit hammer product synchronize --name "Red Hat Enterprise Linux Server" --organization "${ORG}"

doit hammer lifecycle-environment create --name "$LE1" --description "QA testing for the App guys" \
	--organization "${ORG}" --prior "Library"

doit hammer lifecycle-environment create --name "$LE2" --description "Production Environment" \
	--organization "${ORG}" --prior "$LE1"

doit hammer content-view create --name "${CV1}" --description "Our initial first content view" \
	 --organization "${ORG}"

ids=$(hammer repository list --organization "${ORG}" | grep -v Kickstart | awk '/^[0-9]/ { print $1 } '  |  paste -sd,)

doit hammer content-view update --repository-ids $ids --name "${CV1}" --organization "${ORG}"

doit hammer content-view publish --name "${CV1}" --organization "${ORG}"


hammer  architecture list | grep x86_64 || {
	x86_64 architecture missing - bailing out
	exit 1
}

# the domain the sat-server resides is created during install - maybe just add this domain to the location and organization
# we want to manage a subdomain which needs to be created separately (if satellite server is in other domain)
hammer domain list | grep  "$DNSDOMAIN" >/dev/null 2>&1 
if [ $? -eq 0 ] ; then
	# domain allready exists
	doit hammer domain update --name "$DNSDOMAIN" --locations $LOC --organizations "$ORG"
else
	# domain does not exist jet
	doit hammer domain create --name "$DNSDOMAIN" --locations $LOC --organizations "$ORG"
fi

doit hammer content-view version promote --content-view ${CV1} --from-lifecycle-environment Library \
	--to-lifecycle-environment $LE1 --organization "${ORG}"


doit hammer activation-key create --name "${AK1}" --content-view "${CV1}" --lifecycle-environment $LE1 \
	 --organization "${ORG}"

doit hammer activation-key update --release-version "7Server"  --organization "${ORG}" --name "${AK1}"

subid=$(hammer --csv subscription list --organization "$ORG" | egrep -v 'HPC|ARM|SAP|Disaster|ATOM|Hyperscale' | awk -F, '/Red Hat Enterprise Linux Server with Smart Management, Premium \(Physical or Virtual Nodes\)/ { print $1 ; exit } ')

if [ "$subid" == "" ] ; then
	subid=$(hammer --csv subscription list --organization "$ORG" | egrep -v 'HPC|ARM|SAP|Disaster|ATOM|Hyperscale' | awk -F, '/Red Hat Enterprise Linux Server with Smart Management,.*\(Physical or Virtual Nodes\)/ { print $1 ; exit } ')
fi
if [ "$subid" == "" ] ; then
	subid=$(hammer --csv subscription list --organization "$ORG" | egrep -v 'HPC|ARM|SAP|Disaster|ATOM|Hyperscale' | awk -F, '/Red Hat Enterprise Linux Server with Smart Management,.*/ { print $1 ; exit } ')
fi
if [ "$subid" == "" ] ; then
	subid=$(hammer --csv subscription list --organization "$ORG" | egrep -v 'HPC|ARM|SAP|Disaster|ATOM|Hyperscale' | awk -F, '/Red Hat Enterprise Linux Server.*/ { print $1 ; exit } ')
fi
if [ "$subid" == "" ] ; then
	subid=$(hammer --csv subscription list --organization "$ORG" | egrep -v 'HPC|ARM|SAP|Disaster|ATOM|Hyperscale' | awk -F, '/Employee SKU/ { print $1 ; exit } ')
fi
if [ "$subid" == "" ] ; then
	echo "Did not find a valid subscription for the activation key - bailing out"
	exit 2
fi
akid=$(hammer activation-key list --organization "${ORG}" | awk '/'$AK1'/  { print $1 } ')

doit hammer activation-key add-subscription --id ${akid} --subscription-id ${subid} 

if [ $(hammer subnet list | grep '^[0-9]' | wc -l) -eq 0 ] ; then
	# create new subnet
	proxyid=$(hammer proxy list | awk '/^[0-9]/ { print $1 }')
	dnsdomainid=$(hammer domain list | awk '/ '"$DNSDOMAIN"'/ { print $1 }')

	doit hammer subnet create  --dhcp-id $proxyid --dns-id $proxyid --tftp-id $proxyid \
		--network "$NETWORK" --mask "$NETMASK" --gateway "$ROUTER" \
		--dns-primary $DNSSERVER --domain-ids $dnsdomainid --from "${RANGEFROM}" --to "${RANGETO}" \
		--name "${NETWORK}/${CIDRNM}"

	doit hammer subnet update --name "${NETWORK}/${CIDRNM}" --locations "${LOC}" --organizations  "${ORG}"
	 
else
	echo not defined how to deal with existing subnet
	exit 2
fi

# to automate things would need to be sophisticated as the approach is
# 1) look up the right objet
# 2) check the settings of the object
# 3) add missing settings, if necessary

# nothing to do with the provisioning templates - they are associated to $ORG and $LOC wnd my operationg system (RHEL 7.2) without me interfering
# http://gsw-hammer.documentation.rocks/configure_the_server_for_provisioning/provisioning_templates.html

# nothing to do with Operationg system either, partition tables, default templates, architecture and installation media are set properly:
# hammer os list
# hammer os info --id 2
osid=$(hammer os list | awk '/RedHat 7.2/ { print $1 } ')

# medium needed tweeking

mediumid=$(hammer medium list | awk '/Red_Hat_Server/ { print $1 } ')

hammer medium info --id $mediumid | grep "$ORG" >/dev/null 2>&1 || {
      doit hammer organisation add-medium --medium-id $mediumid --name "${ORG}"
}
hammer medium info --id $mediumid | grep "$LOC" >/dev/null 2>&1 || {
      doit hammer location add-medium --medium-id $mediumid --name "${LOC}"
}

cv1id=$(hammer content-view list  --organization "$ORG" | awk '/'"$CV1"'/ { print $1 } ' )
orglabel=$(hammer organization list | awk -F'|' '/'"$ORG"'/ { print $3 } '| tr -d ' ' )

# env1name=$(echo "KT_${orglabel}_${LE1}_${CV1}_${cv1id}" | sed -e 's/-/_/g')
env1name=production

doit hammer hostgroup create --name "$HG1" --architecture "x86_64" --domain "$DNSDOMAIN" \
	--operatingsystem-id $osid --partition-table "Kickstart default" --puppet-ca-proxy-id $proxyid --puppet-proxy-id $proxyid \
	--subnet "${NETWORK}/${CIDRNM}" --content-source-id $proxyid  --medium-id $mediumid \
	--organizations "${ORG}"  --locations "${LOC}" --lifecycle-environment "$LE1" --content-view "${CV1}"
	#### --environment "$env1name" \

doit hammer hostgroup set-parameter --hostgroup "$HG1"  --name "kt_activation_keys"   --value "${AK1}"

# # Puppet env does not exist :-( - it should though
# doit hammer environment create --name "$env1name" --organizations "$ORG" --locations "$LOC"
# doit hammer hostgroup update --name "$HG1" --environment "$env1name" 
# env "production" does exist
doit hammer environment update --name "$env1name" --organizations "$ORG" --locations "$LOC"
doit hammer hostgroup update --name "$HG1" --environment "$env1name" 

# capsule was not in Location Europe
capsuleid=$(hammer capsule list | awk '/^[0-9]/ { print $1 }')
doit hammer capsule update --locations "${LOC}","Default Location" --id $capsuleid

# domain was not managed via capsule
doit hammer domain update --dns-id $proxyid --id $dnsdomainid 

# create syncplan
synctimestring=`date +"%Y-%m-%d %T" --date "$SYNCTIME tomorrow"`

doit hammer sync-plan create --name "dailysync" --enabled yes --interval daily --sync-date "$synctimestring" --organization "$ORG"

syncplanid=$(hammer sync-plan list --organization "$ORG" | awk '/^[0-9]/ { print $1 }')
doit hammer product set-sync-plan --sync-plan-id=$syncplanid --name='Red Hat Enterprise Linux Server' --organization "$ORG" 

# Enable Access insights
doit yum install redhat-access-insights -y 

doit redhat-access-insights --register

doit yum update python-requests -y 

# yust someinternal things:
# https://mojo.redhat.com/docs/DOC-1043937
doit sed -ie 's/:enable_telemetry_basic_auth : false/:enable_telemetry_basic_auth : true/' /etc/redhat_access/config.yml
doit systemctl restart httpd 

echo "Do not forgett to set credentials in Access Insights -> Manage."
echo "Insights is not workingyet :-("

# not working yet


# Enabling OpnSCAP
doit foreman-rake foreman_openscap:bulk_upload:default


# import puppet-classes (e.g. OpenScap) to environments 
doit hammer proxy import-classes --id $proxyid


puppetenvid=$(hammer environment list | awk '/'"$env1name"'/ { print $1 } ')
pupclassids=$(hammer --csv puppet-class list | awk -F, ' /access_insights_client$/ { print $1 }  
/foreman_scap_client$/ { print $1 }
/foreman_scap_client::params$/ { print $1 }'  | xargs | tr ' ' ,)


doit hammer proxy import-classes --id $proxyid --environment-id $puppetenvid
doit hammer hostgroup update --name "$HG1"  --puppet-class-ids  $pupclassids

echo "###INFO: Finished $0"
echo "###INFO: $(date)"
