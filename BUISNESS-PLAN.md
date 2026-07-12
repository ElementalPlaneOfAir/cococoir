# Project Plan

Project repo: https://github.com/ElementalPlaneOfAir/cococoir

## Nicole's Background

This project is born out of my homelab setup at /home/nicole/cococoir. Our previous startup produced AI enabled tools for extracting government data, and we predominately targeted companies that interface w/ utility companies, and nonprofits that do advocacy work with state PUC's. It produced a ton of really cool technology, but really faltered on the consumer demand angle, mostly because 1) it's really good to sell to customers who have money, and 2) I sucked at running a business when I started it 2 years ago. So this is a newer thing that is hopefully going to fare better in that area.

## What we are building and why

Right now we live in a world where peoples lives are more reliant upon a panopticon created by the large tech companies. Yet opting out of said panopticon has never been easier if you have either:

1) The expertise and technical know how to set up a home server 
2) Enough of a distrust of big tech and discontentment with the world at large to motivate them to go through after the initial hassle.

Our big goal is to try and sell this vision of digital sovereignty directly to non-technical consumers, we will do this by directly assembling servers and selling them a complete solution in box. We are also a worker cooperative, which is part of the appeal for some of our potential customers (especially other coops and nonprofits).

There do exist techniques to divide the general population into boxes depending on their proclivity towards adopting new technology. However, I think there is a separate axis that encodes how much technical skill they have. Divide people in society into certain brackets depending on technical skill it might look something like this:

1) Completely Non Technical (These people likely rely on a partner/family/friends or are abstaining as a matter of principle, likely at some personal cost)
2) Console Purchasers/Apple Enjoyers
3) Ordinary PC Users
4) PC Tinkerers
5) Linux Installers
6) CS People

So our main demographic is probably going to be a combination of both relatively non technical people (maybe 2-4 on the previous classification) and maybe the late majority/laggards categories on the early adopters spectrum.

This does mean that we are targeting different things then a normal software startup, or other solutions for running a homeserver.

## Current status and customer plan

Right now we do have 1 customer who has actually placed an order with us for the service and who we actually have a good enough relationship with where they will actually tolerate all the bugs of this service. They are a small nonprofit operating a community center, and right now they are just looking for a single replacement for google docs, maybe later down the road they would want a solution for email and internal communication, but based on conversations with them this is at least a couple months out.

We did debate a bit about where our first 10 customers should come from after this, we could continue to go after some business connections, but after around 20-40 small business leads our personal connections run out. So a pivot into residential might be a good idea, since thats a market where we could find 200-1000 leads without too much of a problem, so I have an impulse that the best customer acquisition plan might look like:

1. Get the google docs and technical stack working for this one business that is willing to put up with alpha quality software (and are also fairly chill).
2. Do a soft pivot into residential for our next 10-20 customers and get the reliability and software quality for this stack to a very high level.
3. Reassess from here about if we should go after small businesses with a more resilient stack, or continue with residential.

This is explicitly a part time thing for everyone involved until we can actually reach the threshold at maybe 300-1000 customers (this varies a lot depending on the economics, which we can hopefully improve a bit) and it can be a full time thing for one of us. (All of us have jobs and are financially stable.)

## What our customers expect

(These mostly just represent my hypothesis for what I think people might want. - Nic)

1. **Time to get up and running trumps almost all other concerns.** 

   Traditionally most of the time you would spend getting a homelab set up would be split between building your hardware and installing your software, then ultimately configuring your server with all the services you might need. I don't think this is tenable for normal people when trying to get this to work. The ideal system for them is 

     a) They get the computer from us.
   
     b) They plug it into the wall, and plug in an ethernet cable.
   
     c) They do an extremely simple account creation process, giving themselves a super simple username and password.
   
     d) They can immediately use all the services.

2. **Configuration is overrated.**

   All the existing server solutions have these really well put together dashboards with recipies for tons of different services.  However, from the perspective of an end user this bazzar of choice is much more of a detriment then a benefit. This also allows us to get out of the "how do we convince developers to use our home server product over thousands of alternatives" and into "how do we convince this random wine mom that a home server is a good purchase".

3. **Performance is absolutely critical, but not for the reasons one traditionally thinks.**

   We as a business have a hard limit on how much we can charge for our service based on what an average residential customer is willing to pay, and most of that in the beginning is going to pay off the server inside their house. If we can make the services we provide more efficent, and reduce our BOM for our 300$ home server from 200$ to 100$ we can essentially double our rate of profit.

4. **Data Resilency**

   There is this expectation in the post dropbox/gdocs era that when you put a document on "the cloud" it will never get lost or deleted. Home servers always have inherent issues with this, so figuring out a good way to have offsite backups for all the software directly out of the gate is a good idea.

5. **Networking and Local Access**

   So most of the ordinary population isn't really aware of how IP resolution works, and as such typical networking behavior, such as not being able to access a local server on their phone is deeply frustrating, and trying to explain that "Oh, but the ip address of the server 192.168.0.69 is only a *local address* that is resolvable only when you are on the same LAN." Doesnt really land. So all the services on the server need to have clear and acessible name like: "jellyfin.username.example.org" and this works and resolves properly when on the same lan, and globally on the wan, all while not comprimising security at all since all the TLS certificates are always held on the device directly.

6. **Unified Account Systems**

   One of the big barriers to setting up a homelab system is the fact that every single service has its own internal system for managing user accounts. So even for all the existing services you will spin up a bunch of them, then have to go through the somewhat laboriuous process of setting up a user for each service, (you can give them all a different password, but that can confuse password managers since they are all on the same domain or ip, or give them all the same, which makes that password impossible to rotate). One of the big things about modern account providers has been the ability to use OAUTH to drastically reduce the friction of making an acount, while also still allowing you to rotate passwords in a secure manner. This stack absolutely needs something similar.

## The product

The core of the product is a 3-part system that makes local services globally accessible, with all cryptographic keys held on the user's local device:

1) **Caddy** (or some other https proxy and certificate management software) runs on the local device, so every service can be multiplexed via domain names.

2) **Rathole** (or some similar proxy) forwards every packet sent to :443 and :80 on a specific ipv4 address to the local caddy service. This both enables ACME certificate requests to be completed behind carrier level NAT, and also enables access to the services globally anywhere on the internet.

3) **DNS** for the domains is redirected locally on the LAN to the server, so users on the same network can access the sites with full https without needing to send anything abroad to anyone.

This also means that no one else can know any of your data, since all the x25519 keys only exist on your local computer in your garage/office. If you are on the LAN, you can do a simple easy check for MITM attacks by comparing the results from:

```
echo | openssl s_client -connect <LOCAL_IP>:443 -servername <TESTDOMAIN> 2>/dev/null \
  | openssl x509 -noout -modulus

echo | openssl s_client -connect <REMOTE_IP>:443 -servername <TESTDOMAIN> 2>/dev/null \
  | openssl x509 -noout -modulus
```

to ensure the keys are identical. (Although you would probably want to provide a script/gui for ease of use.)

## Why is the tech stack the way that it is?

### Coordination Layer

Every home server looks like:
```
Core Layer that interfaces with the hardware. (Drives, Network, CPU, etc.)
(Service 1 that provides a functionality)
(Service 2 that provides a functionality)
(Service 3 that provides a functionality)
An orchestration layer that makes this entire system easy to administer (IE a dashboard)
```
Inside this system there are competing desires/problems.

  a) All of these services need to be independent to some degree, they each require their own execution environments and their own dependancies, and they might conflict with each other.

  b) You need a way to configure all the plumbing for these services in a deterministic way on multiple machines. And you need this to be consistent. If it works on one machine, this should provide you some guarentee that it works on all machines.

  c) You need this layer to be as performant as possible.

  d) You need to be able to update the system with changes to the configuration and services, without disrupting the existing system.

  There do exist solutions for this, which are:
  
1. YOLO it, and start with a blank linux distro and run a bunch of shell commands to install and configure everything.  (This does work, but cannot really be updated effectively, and isn't great for reliability)
   
2. Docker/ Docker Compose. Lets you run all of these processes inside of their own containers with their own dependencies. And then has a higher level configuration language that exposes the networking and routes the configuration files so they are ultimately stored in the right place. Its the industry standard, but does use a fair bit of memory and storage space (cpu overhead is a bit better) compared to just running the application directly on the computer.
   
3. NixOS - Gives you all the performance of native, and also lets you sandbox dependencies and build everything in a determinstic way. You pay for this because its the most finely complicated evil software ever created. (Disclosure: I have been using this as my daily driver for 4 years, and am at a point where I feel almost comfortable enough to use it for this project. - Nic)
   
### Storage Layer
   
I am still trying to configure this by using garage (https://garagehq.deuxfleurs.fr/) which is an implementation of something that is kinda like a file system, but eliminates some of the functionality so that its a lot more performant over a network and multiple computers, namely both S3 and traditional file systems let you:

- Create Files.
- Delete Files.
- Organize Files in Folders (Folders in s3 technically don't exist, but you can still navigate and name them like folders so mostly the same)
- Recursively list all the files that are either in a folder, or begin with a certain path.
- Delete a folder/path prefix by recursively deleting all the files inside a folder.

But S3 does **NOT** have the functionality that exists in most normal file systems:
- The ability to move a files without the disk usage associated with deleting and adding the file.
- The ability to move a folder without recursively moving all the files in a folder.
   
Most of this is trying to get better performance inside the limitations of the CAP theorem (https://en.wikipedia.org/wiki/CAP_theorem), but a part of it has to do with the fact that most file systems are implemented using Trees/BTrees and inheret a lot of their properties from them, however Trees/BTrees are somewhat incapable of running in parallel either on the same machine or multiple machines, so S3 decided to go with HashMaps which handle parallelism much better as a Distributed Hash Map, but you give up certain properties as a result. 
   
(Fun Fact: This is also why running Postgres/ any other SQL database across multiple machines is the worlds biggest royal PITA, but all the hip new nosql key value stores like redis/valkey come with support for multiple nodes right out of the box. Most of the postgres internals need to be implemented with BTrees, where redis is able to use distributed hashmaps)
   
### Networking Layer
   
Okay so for this main application we are looking for something that takes all network traffic going to <user-specific-ip>:(80 or 443 or 22), and forwards it to the users homelab at those specified ports. Then the DNS resolution for all the services adds A records for everything. Then the local DNS for the LAN is rerouted to the <lan-server-ip>, just so that it doesn't use up our bandwidth for local requests, but the records might look like
- GLOBAL jellyfin.username.example.org A <user-specific-ip> LOCAL jellyfin.username.example.org
- cryptpad.username.example.org A <user-specific-ip> LOCAL jellyfin.username.example.org
 
And then the routing for this is handled by caddy internally. But what caddy doesnt handle is specifically 
- Proxying the network traffic from the global system on to the local one.
- Keeping track of used bandwidth for each individual customer.
- Handling the provisioning for this system, where we have a cluster of N machines with an assigned K ip addresses, and when a new user registers we need to request another IP address be assigned to a node, then we need another system that will automatically provision the DNS system to add new entries for new services. (Although it might be worth having it just assigned on the *.username.example.org, and instead of being a username there is a name for each server, although I also kind of want to make the system generalizeable to a cluster with multiple machines across different locations, more thinking on this is good.)
   
### Reliability Layer
   
I also think its very good for this system to have an administration/reliability layer, that in general for all the services.
- Checks to make sure that all the services are alive and working.
- Can run a series of tests to make sure they are at least behaving as expected.
- Administer the system and provide a dashboard to people.

## Existing Homelab software providers & should we write our own or not

| Project | Home page | GitHub repo |
|---|---|---|
| YunoHost | https://yunohost.org | https://github.com/yunohost/yunohost |
| CasaOS | https://casaos.zimaspace.com/ | https://github.com/IceWhaleTech/CasaOS |
| Umbrel | https://umbrel.com | https://github.com/getumbrel/umbrel |
| Cosmos | https://cosmos-cloud.io/ | https://github.com/azukaar/Cosmos-Server |
| Cloudron | https://cloudron.io | https://github.com/cloudron-io |
| Synology | https://www.synology.com/ | https://github.com/SynologyDocs |
| TrueNAS | https://www.truenas.com/ | https://github.com/truenas |
| Runtipi | https://runtipi.io/ | https://github.com/runtipi/runtipi |
| Homarr | https://homarr.dev | https://github.com/homarr-labs/homarr |
| Dokku | https://dokku.com/ | https://github.com/dokku/dokku |
| Coolify | https://coolify.io/ | https://github.com/coollabsio/coolify |

Admittedtely I havent tried all of these, but of every version I have tried, all of them are in the docker ecosystem, and mostly seem to be designed with the intention to allow a lot of flexibility for every application, instead of focusing on really deep integration with a very small curated set of apps. But I am willing to change my mind on this.

## Market context: what people currently pay

You can essentially provide a list of services that map to what a typical residential customer is paying for SaaS today:

- Cloud Storage - 10 dollars a month for 2tb - 120$ a year
- Password Managers = 4$ a month - 48$ a year. (Also importantly almost no one uses password managers, and of the minority that do, an even smaller minority pay for them.)
- Ring Cameras - 4$ a month - 48$ a year (notably this only gets you saved footage off your existing ring cameras, the cameras still proxy through one of their API endpoints so it doesnt actually get you any major privacy benefits)

18$ per month total.

## Cost accounting for customers

- The computer itself:
  - Small arm SBC - 30$ (also add on 40% for shipping and tarrifs)
    - https://www.alibaba.com/product-detail/Original-Orange-Pi-Zero-3W-4GB_1601831697120.html (Higher end) (35$ pre tarrif, 50$ post tarrif)
    - https://www.alibaba.com/product-detail/Orange-Pi-Zero-2W-1G-1_1601155488654.html (Lower end) (15$ pre tarrif, 25$ post tarrif)
  - Used 4tb HDD SAS drive - 60$ (prices vary a lot, set up a chron job w/ some kind of deep research agent to find good listings daily on ebay for SAS and SATA HDDs of sized 8tb, 4tb, 3tb, 2tb, 1tb)
  - SAS to USB Adapter - 22$ (SATA to USB adapters are in the neighborhood of 3-4$ per unit)
  - 3d printed case - 10$
  - power supply and other misc - 20$
142$
good profit margin sell for 300?

If we make 150 per computer that goes to fix costs and overhead.

Ongoing Costs:
- Fully end 2 end encrypted, access the website from anywhere, even if the computer is in your house. (We have a server in the cloud that recieves encrypted data and proxies it to the server)
3-4$ a month in costs - 36-48 $A Month. 5$ A month - 60$ a year. (Maybe higher, just because it's a very essential feature.)
- Encrypted full server backups - 10$ per 2 tb per month? 40$ per 4 tb drive, 2 month payback period on the drives, 6 months if you want to triply duplicate it.
(For the first few customers, it might be a good idea to give backups for free? Just because they are taking a risk with software that might still have bugs)
- Tech Support - 40$ per person hour?
 
Question: Do we ship them out? (Shipping is 20$)

## Pricing model

The plan is to offer both a one-time purchase and a subscription option, to accommodate two different customer types: people who are explicitly anti-subscription (the "pay $400 cash and never talk to you again" segment) and people who would prefer a subscription to spread the upfront cost. The principle is that customers get full ownership of their data either way - the subscription just covers the ongoing services (remote access tunnel, encrypted backups, support).

For reference, our current rough pricing for the ongoing services is:

- **Remote access** (encrypted tunnel + ipv4 + 100GB-1TB egress): ~$5/month in costs, possibly priced higher since it's an essential feature
- **Encrypted offsite backups**: ~$10 per 2TB/month
- **Tech support**: $40/hour, or included with a support contract

(Notably, torrenting is a use case that exists in the background, but it is not something we can feature in marketing. The privacy and ownership story is the actual pitch - other uses of the box are a natural consequence of owning it.)

## Honest concerns and open questions

### Why we are not leading with B2B

I don't know if the consumer demand is really all its cracked up to be on this. It's probably better then our previous product. The big issue that I think we are going to run into is that most businesses fall into the two categories of:

- Don't really care at all about information security and are likely to just go ahead and use the basic offerings by google and microsoft.
- At a larger scale you have more confidential data and also more cloud storage usage, which would make us a good alternative, except customers in this bracket are a lot more likely to go with well established companies that have large b2b sales teams.

So this is still a bit of a problem. There are some businesses that have a ton cloud storage, and hosting it locally would save them a fair bit of money. And going with an enterprise b2b option would actually be cost prohibitive. This also might be true of a company with lots of seats, but any company with a lot of employees is going to have lots of revenue to pay all of said employees, so its less relavent in that case.

Another idea might be an "upgradeable pathway" where we start off with a subscription on our own hardware, then at any point in time you can buy a tower for us and we will get it set up at your office in a perfectly seamless adjustment, with all your old data and settings getting perfectly transfered over.

There are also some businesses like nonprofits and other worker cooperatives in denver that might be interested in this from a purely ideological angle, and those also tend to be the businesses who we have the most connections to at the moment. 

### Worries about a B2B Model Targeting Small Businesses

Big problem #1 is that even though the market for small businesses might seem enormous, (ie 80% of all businesses have 5 or fewer employees), they only comprise 5-7% of all revenue made by businesses. 

I would also guestimate that "cloud services for small businesses" tends to be extremely oversaturated compared to the size, just because one way to go after the "big business" market is to try and get customers when the firms are small. You even see lots of companies do loss leaders, and give away services for free on the low end so that you can lock firms into your service and upcharge them massively once they get bigger. The best example of this would probably be cloudflare which provides **unlimitted free bandwidth** with ddos protection and other services, and really only makes money on its 100k+ per year enterprise contracts. From CF's perspective it makes total sence to take on operating costs associated with 5-7% of the market, if it means they can continue their monopoloy as the best internet services and ddos protection worldwide. (This also has the benefit of keeping startups from getting the easier small business market).

This does mean that there are businesses who might value the product or hosting their infrastructure on prem for ideological reasons. And since all 4 of us who are starting this do have at least some experience in the nonprofit and cooperative space, and do have local contacts in this space, which would probably at least make getting initial customers a bit easier. But I also do know that the scene isn't that big, even if you somehow were the primary provider for every single cooperative or nonprofit, its probably not enough to sustain 1-2 people's salary once you subtract all the costs.

(Also businesses really prioritize reliability, and while you can get that at a local scale, its going to be a lot easier to provide that by giving them a share of a 1000 node computer/k8s cluster, then trying to do everything on a machine they own locally.)

This line of thinking is making me think that targeting the residential home server use case might be a bit better. The big benefit of this is that it has a much bigger TAM then the small business use case. (I also think that most of the really hard technical details, IE provisioning, fully reliable networked storage, and centralized user accounts are actually shared between residential and business, so an overlap might not be super ridiculous).

### Secured Loan Model (exploratory, not adopted)

This is a pricing idea we considered but haven't adopted. User signs a contract, pays 20-30% up front, takes out a loan from us with $30/month payments. If they default, we just take the computer back (with a "you're behind on payments" notification). Customers can cancel by returning the computer, pause and resume later, or pay off the computer proactively. The Klarna comparison is apt - this is "super evil" - and residential default risk is real, so we're not sure this is the right move. It would be less of a concern for businesses.

### Unit economics

We have not done a full unit economics analysis yet. Our rough target: in order for one of us to go full-time, we need on the order of a thousand customers. The actual number depends on churn, support burden, and recurring vs one-time revenue mix. This is a key next step.

## Helpful Videos

  *Programming style video:* https://www.youtube.com/watch?v=w3WYdYyjek4
   
*Video of people trying linux for the first time:* https://www.youtube.com/watch?v=0506yDSgU7M
