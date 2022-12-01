# Choosing a Versioning Schemes

This document records our discussions around choosing how to version our packages.

## Desiderata

- *Simplicity and Familiarity*. We'd like the versioning scheme to be simple to explain, and ideally already well-established.

- *Ease of execution*. We'd like the process of cutting a release to merely involve following a very simple checklist. We'd like it to require as few inputs, discussions, decisions, etc.

- *Distinguished development versions*. We'd like to distinguish between the two possible semantics of version number.

    - The version of a released thing identifies some immutable thing, which is always somehow more refined than any release that has a lesser version number.

    - A development version refers to some _mutable_ thing that is improving during the time between two releases, eg the version on master. IE there will usually be multiple different commits that all have the same development version number.

## Proposal Simplest

To cut a release, merely create branch release/XXX pointing at the desired commit on master and also immediately create a subsequent master commit that advances all the appropriate versions.

## Proposal Parity

Minor versions will be odd for packages on master and even for releases (like the GHC Team's scheme).
To cut a release, create branch release/XXX pointing at the desired master commit and then add a commit to release/XXX that bumps all versions to the next even number, and also immediately create a subsequent master commit that advances all the appropriate versions to the next odd number.

## Proposal NonZero

Master always has degenerate versions on it: everything is version 0.
To cut a release, create branch release/XXX pointing at the desired master commit and then add a commit to release/XXX that advances all appropriate versions COMPARED TO their value in the previous release branch.

## Proposal Dimension

FYI

```
Prelude Data.Version> makeVersion [1,2,0] `compare` makeVersion [1,2]
GT
```

Master versions only have two dimensions: major.minor.
Release have at least three major.minor.patch, where patch can be 0. To cut a release, create branch release/XXX pointing at the desired master commit and then add a .0 patch dimension to the existing major.minor and immediately create a subsequent master commit that advances all appropriate versions to the next greater major.minor pair.