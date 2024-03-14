# Ubiquiti EdgeRouter-X (ER-X) patches

This repo contains patches that fixes some of the lacking features/bug of the edgerouter-x (and I guess all devices using version 2 of the firmware).


## Static IPv6 route on route-table lacking interface
It is (was) not possible to specify an interface when declaring a static route
on a specific route table.

This works on static routes, but not on route tables.

This now works (see the commit) and enables things like:
```vyatta
protocols {
    static {
        table 10 {
            route6 ::/0 {
                next-hop fe80::2066:cfff:fe61:54e3 {
                    interface eth3
                }
            }
        }
    }
}
```
This is useful (mandatory, even), when using link-local addresses
