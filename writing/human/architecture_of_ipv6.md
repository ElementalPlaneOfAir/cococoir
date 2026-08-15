Okay, so here is how I invision the architecture for this working.


We have on one end:

A homelab user, let us call them example123 with a domain

*.example123.interdim.net

and a homelab server behind an ipv4 cgnat, along with a caddy instance trying to host services like

https://jellyfin.example123.interdim.net 

then it has a global ip box with the following:

- A single global IPv4 address

- Around 64-256 ipv6 addresses. (Or more realistically a /64 or /96 for a ton more addresses)

(Worrying about the best way to provision multiple devices or ensure they have a good number of IP's in an automatic manner can be saved until later)

Along with the following DNS records 

- interdim.net has an A record pointing to the single IPv4 address.

- For each of our 20-30 customers with a username <username>, we will have a AAAA record on *.<username>.interdim.net pointing to one of our machines IPV6 address.

Then the machine will take any traffic recieved on a bound IP address and forward it to the customers machine who requested it on said IP layer. (In kind of a similar manner to rathole), if the customers machine doesn't support IPv6 it might just use a port combo with its publicly accessible IPv4.

This allows the following relatively easily:

- Caddy on each users server can get real certs since the ACME requests get blindly forwarded along with everything else.
- For most cases outside of a home network people are going to be on cell phones which means that they can access the server by hitting the public ipv6 address associated with their domain.
- For a local network you can access it using a custom DNS server. And even though the cert was originally gotten with ipv6 you can still use that on a local network that only has IPv4.


