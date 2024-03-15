#!/bin/bash
files=(opt/vyatta/sbin/ubnt-multi-table.pl opt/vyatta/share/vyatta-cfg/templates/protocols/static/table/node.tag/route6/node.tag/next-hop/node.def opt/vyatta/share/vyatta-cfg/templates/protocols/static/table/node.tag/route6/node.tag/next-hop/node.tag/interface/node.def)


for f in ${files[@]}; do
	echo ">>$f";
	bn=$(basename $f)
	scp $f ubnt@192.168.10.254:/tmp/$bn
	ssh ubnt@192.168.10.254 "sudo mv /tmp/$bn /$f"
done
