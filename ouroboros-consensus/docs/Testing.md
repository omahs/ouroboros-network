# Property testing in the consensus layer

> This document corresponds to 95c765081c0edf233f16f5efe046ede523e70cc5 .

The vast majority of the tests in the consensus layer are QuickCheck property
tests, and many of these are model based. There are only a handful of unit
tests. The consensus layer is an intricate piece of software with lots of
components, which we set at virtually every level of granularity. Below we  give
an overview of the tests that we do per component. For the detailed listing,
please refer to the various test suites within the
[repository](https://github.com/input-output-hk/ouroboros-network/); at the time
of writing, this is

* `ouroboros-consensus-test/test-infra/Main.hs`
* `ouroboros-consensus-test/test-storage/Main.hs`
* `ouroboros-consensus-test/test-consensus/Main.hs`
* `ouroboros-consensus/ouroboros-consensus-mock-test/test/Main.hs`
* `ouroboros-consensus-byron-test/test/Main.hs`
* `ouroboros-consensus-shelley-test/test/Main.hs`
* `ouroboros-consensus-cardano/test/Main.hs`

Throughout this document we mention rough lines of code statistics, in order to
get a sense of the cost of the testing. Some common code that is used by many
components is not included in these statistics. Moreover, the consensus layer
contains some 10k additional lines of code that is not accounted for in any
of the statistics below; this is generic infrastructure that is used by all
components.

## Testing the test infrastructure

The library `ouroboros-consensus-test` provides a bunch of test utilities that
we use throughout the consensus layer tests. It comes with a few tests of its
own. Some examples:

* Some consensus tests override the leader schedule from the underlying
  protocol, instead explicitly recording which nodes lead when. If we use a
  round-robin schedule for this, and then compute the expected fork length, we'd
  expect to get no forks at all.
* Some invariants of various utility functions.

There isn't too much here; after all, if we start testing the test, where does
it stop? :) That said, `test-consensus` contains a few more tests in this same
category (see below).

**Stats.** The `ouroboros-consensus-test` library itself is 8,700 lines of code.
Since this library is used throughout all tests, I've not added that line count
to any of the other statistics. The test suite for the library is minute, a mere
140 loc.

## The storage layer (`test-storage` test suite)
### The Immutable DB (`Test.Ouroboros.Storage.ImmutableDB`)

The immutable DB bundles a (configurable) number of blocks into "chunk files".
By design, chunk files are literally just the raw blocks, one after the other,
so that we can efficiently support binary streaming of blocks.

Every chunk file is accompanied by two indices: a _primary_ index that for
each slot in the chunk file provides an offset into a _secondary_ index, which
stores some derived information about the blocks in the chunk file for
improved performance. Both the primary and the secondary index can be
reconstructed from the chunk file itself.

The tests for the immutable DB consist of a handful of unit tests, a set of
property tests of the primary index, and then the main event, model based
checking.

**Stats.** The implementation is 6000 loc. The tests are 2700 loc.

#### The primary index (`Test.Ouroboros.Storage.ImmutableDB.Primary`)

This is a sequence of relatively simple property tests:

* Writing a primary index to disk and then reading it again is an identity
  operation (`prop_write_load`)
* We can create new primary indices by appending new entries to them
  (`prop_open_appendOffsets_load`)
* We can truncate primary indices to particular slot.
* Finding and reporting "filled slots" (not all slots in a chunk file, and
  hence in a primary index, need to contain a block) works as expected.
* Reconstructing a primary index from the same data results in the same
  primary index.

Of course, these (and all other) property tests are QuickCheck based and so
generate random indices, random slot numbers, etc., and come with a proper
shrinker.

#### Model based testing (`Test.Ouroboros.Storage.ImmutableDB.StateMachine`)

This is the main test for the immutable DB. As in any model based, we have a
set of commands, which in this case corresponds to things like

* Read a block, or information about a block, from the DB
* Append a block to the database
* Stream blocks from the DB
* etc.

In addition, there are commands that model disk corruption, so that we can test
that the DB does the right thing in the presence of disk failure. The consensus
storage layer has a simple policy for disk corruption: _it is always sound to
truncate the chain_; after all, we can always get the remaining blocks from
other peers again. This means that in the models, disk corruption is simply
modelled as truncation of the chain; the real thing of course needs to be able
_detect_ the corruption, minimize quite how far we truncate, etc.

The model (defined in `Test.Ouroboros.Storage.ImmutableDB.Model`) is essentially
just a mapping from slots to blocks. It needs to maintain a _bit_ more state
than that, in order to deal with stateful API components such as database
cursors, but that's basically it.

### The Volatile DB (`Test.Ouroboros.Storage.VolatileDB.StateMachine`)

The set of commands for the volatile DB is similar to the immutable DB, commands
such as

* Get a block or information about a block
* Add a block
* Simulate disk corruption

in addition to a few commands that are supported only by the volatile DB,
such as "find all blocks with the given predecessor" (used by chain selection).
The model (defined in `Test.Ouroboros.Storage.VolatileDB.Model`) is a list
of "files", where every file is modelled simply as a list of blocks and some
block metadata. The reason that this is slightly more detailed than one might
hope (just a set of blocks) is that we need the additional detail to be able
to predict the effects of disk corruption.

**Stats.** The implementation is 1600 loc, the tests are 1300 loc.

### The Ledger DB (`Test.Ouroboros.Storage.LedgerDB`)

The ledger DB consists of two subcomponents: an in-memory component, which is
pure Haskell (no IO anywhere) and so can be tested using normal property tests,
and the on-disk component, which is tested with a model based test.

**Stats.** The implementation is 1400 loc, the tests are 1600 loc.

#### In-memory (`Test.Ouroboros.Storage.LedgerDB.InMemory`)

The in-memory component of the ledger DB is a bit tricky: it stores only a few
snapshots of the ledger state, in order to reduce memory footprint, but must
nonetheless be able to construct any ledger state (within `k` blocks from the
chain tip) efficiently. The properties we are verify here are various
invariants of this data type, things such as

* Rolling back and then reapplying the same blocks is an identity operation
  (provided the rollback is not too far)
* The shape of the datatype (where we store snapshots and how many we store)
  always matches the policy set by the user, and is invariant under any of
  the operations (add a block, switch to a fork, etc.)
* The maximum rollback supported is always `k` (unless we are near genesis)
* etc.

#### On-disk (`Test.Ouroboros.Storage.LedgerDB.OnDisk`)

This is a model based test. The commands here are

* Get the current ledger state
* Push a block, or switch to a fork
* Write a snapshot to disk
* Restore the ledger DB from the snapshots on disk
* Model disk corruption

The model here is satifyingly simple: just a map from blocks to their
corresponding ledger state.

## Miscellanous tests (`test-consensus` test suite)

This test suite contains tests for a number of components of the rest of the
consensus layer.

### The hard fork combinator: time infrastructure

One of the responsibilities of the HFC is to offer time conversions (slot to
epoch, wall clock to slot, etc.) across era transitions (which might change
parameters such as the slot length and the epoch size). It does this by
constructing a "summary" of the current state of the chain, basically recording
what the various slot lengths and epoch sizes have been so far, and how far
ahead we can look (the so-called "safe zone": if the transition to the next era
is not yet known, there must exist a limited period after the ledger tip in
which we can still time conversions).

**Stats.** The HFC history implementation (not the combinator) is 1300 loc;
the tests are also 1300 loc.

