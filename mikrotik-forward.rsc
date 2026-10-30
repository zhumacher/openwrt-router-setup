# Run on the upstream MikroTik. Set forwardTargetAddress and forwardTargetPort locally.
# RouterOS WAN list must already contain the Internet-facing interface.
{
    :global forwardTargetAddress;
    :global forwardTargetPort;
    :local targetIp [:tostr [:toip $forwardTargetAddress]];
    :local portNumber [:tonum $forwardTargetPort];
    :if ([:typeof [:toip $forwardTargetAddress]] != "ip") do={ :error "Set forwardTargetAddress to the client IPv4 address first."; };
    :if ([:typeof $portNumber] != "num") do={ :error "Set forwardTargetPort to a TCP port first."; };
    :if (($portNumber < 1) || ($portNumber > 65535)) do={ :error "TCP port must be in 1..65535."; };
    :local targetPort [:tostr $portNumber];
    :local ruleTag ("managed-forward-" . $targetPort);
    :local leaseId [/ip dhcp-server lease find where address=$targetIp];
    :if ([:len $leaseId] != 1) do={ :error "Expected one DHCP lease at the target address. No changes made."; };
    :if ([/ip dhcp-server lease get $leaseId status] != "bound") do={ :error "Target DHCP lease is not bound. No changes made."; };
    :if ([:len [/interface list find where name="WAN"]] != 1) do={ :error "WAN interface list is missing. No changes made."; };
    :if ([:len [/interface list member find where list="WAN"]] = 0) do={ :error "WAN interface list has no members. No changes made."; };

    :local conflicts [/ip firewall nat find where chain="dstnat" and protocol="tcp" and dst-port=$targetPort and disabled=no and comment!=$ruleTag];
    :if ([:len $conflicts] > 0) do={ :error "The TCP port already has another NAT rule. No changes made."; };
    :local natId [/ip firewall nat find where comment=$ruleTag];
    :local filterId [/ip firewall filter find where comment=$ruleTag];
    :if (([:len $natId] > 1) || ([:len $filterId] > 1)) do={ :error "Duplicate managed rules. Review configuration first."; };
    :if ([:len $natId] = 1) do={
        :if (([:tostr [/ip firewall nat get $natId to-addresses]] != $targetIp) || ([:tostr [/ip firewall nat get $natId to-ports]] != $targetPort) || ([/ip firewall nat get $natId disabled] = true)) do={ :error "Managed NAT rule was changed. Review configuration first."; };
    };
    :if ([:len $filterId] = 1) do={
        :local actualDst [:tostr [/ip firewall filter get $filterId dst-address]];
        :if ((($actualDst != $targetIp) && ($actualDst != ($targetIp . "/32"))) || ([/ip firewall filter get $filterId action] != "accept") || ([/ip firewall filter get $filterId disabled] = true)) do={ :error "Managed filter rule was changed. Review configuration first."; };
    };

    :if ([:len [/file find where name="before-managed-forward-firewall.rsc"]] = 0) do={ /ip firewall export file=before-managed-forward-firewall; };
    :if ([:len [/file find where name="before-managed-forward-leases.rsc"]] = 0) do={ /ip dhcp-server lease export file=before-managed-forward-leases; };
    :local addedNat false;
    :local addedFilter false;
    :do {
        :if ([:len $natId] = 0) do={
            /ip firewall nat add chain=dstnat in-interface-list=WAN protocol=tcp dst-port=$targetPort action=dst-nat to-addresses=$targetIp to-ports=$targetPort comment=$ruleTag;
            :set addedNat true;
            :if ([:len [/ip firewall nat find]] > 1) do={ /ip firewall nat move [/ip firewall nat find where comment=$ruleTag] [:pick [/ip firewall nat find] 0]; };
        };
        :if ([:len $filterId] = 0) do={
            /ip firewall filter add chain=forward in-interface-list=WAN connection-nat-state=dstnat connection-state=new,established,related protocol=tcp dst-address=($targetIp . "/32") dst-port=$targetPort action=accept comment=$ruleTag;
            :set addedFilter true;
            :if ([:len [/ip firewall filter find]] > 1) do={ /ip firewall filter move [/ip firewall filter find where comment=$ruleTag] [:pick [/ip firewall filter find] 0]; };
        };
        :if ([/ip dhcp-server lease get $leaseId dynamic] = true) do={ /ip dhcp-server lease make-static $leaseId; };
    } on-error={
        :if ($addedNat) do={ /ip firewall nat remove [/ip firewall nat find where comment=$ruleTag]; };
        :if ($addedFilter) do={ /ip firewall filter remove [/ip firewall filter find where comment=$ruleTag]; };
        :error "Setup failed. Newly added firewall rules removed; backups are in Files.";
    };
    :put ("FORWARD_OK: TCP " . $targetPort . " -> " . $targetIp . ":" . $targetPort);
    :put "Target DHCP reservation is static. Backups are in Files. No reboot required.";
    :put "WAN addresses (a public IPv4 is needed for inbound SSH):";
    :foreach member in=[/interface list member find where list="WAN"] do={
        :local iface [/interface list member get $member interface];
        /ip address print where interface=$iface;
    };
}
