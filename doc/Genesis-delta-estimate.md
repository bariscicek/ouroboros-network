nick.frisby@iohk.io
2020 April 22

# Introduction

This document demonstrates how the current behavior of ChainSync and BlockFetch
influences our estimate for the papers' `Δ` parameter.

# Semantics of the Δ parameter

Here is a paraphrased quote from a 2020 April 21 phone call with Peter Gaži and
Alexander Russell.

> If a(n honest) leader is about to forge a block at the onset of slot `s+Δ`,
  it must have already had the opportunity to select every (honest) block
  forged as of the onset of slot `s`.

I don't know if this is consistent with other presentations, but here I intend
for `Δ=1` to correspond to the _synchronous_ case, in which alls blocks from
one slot will have been considered for selection by the next slot's leaders
before they lead. If we intead were to use `Δ=0` for synchronous case, then
we'd have to strew `+1`s thoughout.

In other words, we assume `Δ>0`.

We also have the addendum that Edsko and Peter identified during our broad call
earlier that same day.

> If any block violates the above definition of `Δ`, then it can be
  reclassified as adversarial behavior.

(You can probably skip to Example 1 now, if you like.)

For quick reference, I've collated the relevant excerpts of [the Genesis
paper](https://eprint.iacr.org/2018/378) that mention "delay", though they seem
less helpful for this document's purposes than the above.

> More specifically, we will describe a parameter called `Delay` (a function of
  the network delay `Δ`) that determines the time sufficient for a party with
  access to all resources to become fully synchronized with the state of the
  protocol.

> A party is considered synchronized if it has been continuously connected to
  all its resources for a sufficiently long interval and has maintained
  connectivity to these resources ... until the current time. Formally, here,
  "sufficiently long" refers to `Delay`-many rounds [ie slots], where `Delay`
  is a parameter of the ledger that depends on the network delay [ie `Δ`].

> [The statement of Theorem 3 considers only a `Delay` of `2Δ`.]

> [T]he synchronization time does not take more than `Delay` time as given in
  the theorem statements, as this is exactly the time until the a newly joining
  party will have received a synchronizing chain and all honest transactions
  that were sent out (and still are valid) before this party joined the network
  (note that the round-trip time is just 2Δ).

> Δ [is] maximum message delay in slots [note well that a message in the paper
  consists of an entire chain]

(I'm not sure whether it does, but note that if the paper takes synchrony to
mean `Δ=0` -- whereas we here use `Δ=1` for that -- then the paper might
consider synchrony to imply `k*Δ=Δ`.)

# Example 1

Here is a small example.

 * Consider a network with just two nodes, N1 and N2.

 * Let C1 and C2 be the chains selected by N1 and N2 as of the onset of slot
   `s`.

 * Suppose `len(C1) = len(C2)`, so the two nodes are in a stand-off.

 * Let `0 <= div(C1,C2) <= k` denote the depth of their intersection. (It's 0
   iff `C1 = C2`.)

 * Suppose only N1 leads slot `s`, only N2 leads slot `s+Δ`, and no other slots
   have leaders. (So there are `Δ-1` many empty/inactive slots between `s` and
   `s+Δ`.)

 * Let C1' be the chain that N1 forges in slot `s`. Note that `1 <= div(C1',C2)
   = div(C1,C2)+1 <= k+1`.

 * By the semantics of `Δ`, when N2 leads slot `s+Δ`, it must extend C1', since
   C1' is better than C2 and was forged `Δ` many slots ago in slot `s`.

 * Thus N2 has `Δ` many slots (ie `{s .. s+Δ-1}`) in which to fetch
   `div(C1',C2)` many blocks. That ranges from `1` to `k+1` blocks.

# Discussion 1

The last bullet point from that example means that `Δ` should be the maximum
time it takes to diffuse `k+1` blocks (assuming nominal network circumstances,
at least for now). By just naive multiplication, that could be multiple hours!
(Assuming `k=2160` and the worst-case for a single block is 3-5 seconds.) That
seems infeasibly long.

I'm aware of one way to avoid such a huge `Δ`: we can invoke the addendum. We
choose a more reasonable `Δ` and classify any chain-transfer delays that exceed
it as "additional" adversarial behavior. (TODO so incorporate it instead by
lowering the α parameter?.) That approach requires two estimates: the
reasonable `Δ` and the probability it will be exceeded.

I haven't fully worked through it, but I initially anticipate that those two
estimates would both require knowing the PMF/CMF of `1 <= div(C1',C2) <= k+1`
(TODO how likely is that PMF independent of `Δ`?) and also a family of PDF/CDFs
for network latency/delay/etc to transfer `n`-many blocks, or some further
estimates thereof.

(TODO Simlar to the mitigation option mentioned in Discussion 3 below, we could
adjust the fetch logic thread to also fetch blocks from chains that are "just
as good" as the local node's selected chain.)

# Example 2

There is another factor.

 * Suppose instead that we have a linear topology N1 <-> N2 <-> N3.

 * Reconsider the above example assuming that N2 and N3 start with the same
   chain and that N3 instead of N1 leads slot `s+Δ`.

 * Thus the necessary blocks must diffuse from N1 via N2 to N3 within `Δ` many
   slots.

 * In particular, this diffusion happens in two phases, since N2 doesn't begin
   forwarding the diffused blocks until it selects C1'. First, the blocks must
   diffuse from N1 to N2. Then -- only once they've all arrived at N2 -- the
   blocks will begin diffusing from N2 to N3. So, for example, we have `Δ/2`
   slots to get the blocks from N1 to N2 and then `Δ/2` blocks to get them from
   N2 to N3. (And this is even ignoring the intermediate phase where N2 has to
   first send all the headers to N3, so that N3 can decide to start fetching
   the blocks.)

# Discussion 2

The only idea I have for mitigating such a cascade that linearly inflates `Δ`
is to refine the ChainSync server.

> [NJD] I am not certain that this is a reasonable scenario. Operational 
  nodes will have a mimimum connection valency than 2 and they will actively
  work to maintain that (likely to be 5 to 7 range as a minimum of "hot"
  connections - ones that they subscribe to for updates). There will also
  be some level of "is there an eclipse trying to be be performed on me"
  detection that would have triggered a long time before `k` slots of gap
  would start to be approached. [\NJD]

Currently, the ChainSync server provides the local node's selected chain's
headers to its peers' ChainSync clients. So N2 cannot begin diffusing any
prefix of C1' to N3 until N2 has selected the full C1'. And it can't do so
before it has fetched all of C1'.

If instead the ChainSync server were to *additionally* provide the headers of
the chain that the local node's fetch decision logic is attempting to fetch in
anticipation of selecting, then the diffusion from N1 to N2 and the diffusion
from N2 to N3 could be pipelined.

(Is there perhaps a ticket for this behavior? I recall seeing the phrase
"Tentative headers" in a component diagram in the old `network.pdf`. It might
make sense to leave ChainSync as-is and instead introduce a separate
TentativeChainSync.)

I have not considered the ramifications of such an adjustment to ChainSync.

# Discussion 3

In the 2020 April 21 calls, Neil Davies had mentioned a couple other scenarios
to consider.

 * network partition on the order of days, eg undersea cable cut
 > [NJD]Our approach to this is to "ensure" (e.g. get large scale / multiple 
   stakepool operators) to "circle" the world - this is the current
   approach in the federated setting. By having fixed interconnects 
   between say Frankfurt, Singapore and Ohio that ensures that (in the
   absence of major failures) the traffic goes both east and west. 
 >    
 > IP routing will "recover" but, as we saw this week (AWS S3 issues /
   github performance etc) with a US cable cut, many services are implicitly
   dependent on worst case service bounds (on the delay and loss of their
   packet exchanges) and do not degrade gracefully under such conditions.
 >  
 > My main concern here is not the steady state, but the dynamics, we can 
   quantify this during initial deployments by use of suitable tracing and
   analysis. Gut feeling is that our design/implementation should cope - but
   we need to build in the verification. A lot of these gross failures that 
   are seen in large scale services have short term failures that are not 
   captured or just plain ignored. Best intution is that this is a sort of 
   condensation phenomena that needs to be tracked for long term stablity.
 >       
 > A decentralised system does not have the fallback that there is a single
   management entity that can "fix" issues - and that is the fallback situtation
   for all the current players in the larger scale internet.
   [/NJD]
       

 * network partition on the order of minutes, eg BGP (?) reroute.

If I understood the discussion correctly, it's a business-level decision for
now to exclude those from our `Δ` estimate and instead regard those as a
significantly large but temporary absence of honest stake. (TODO so incorporate
them into the [the Genesis paper](https://eprint.iacr.org/2018/378)'s α and β
parameters?)