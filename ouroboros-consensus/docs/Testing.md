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

