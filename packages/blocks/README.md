Terminology:

- Block: A piece of data that is owned by a block and may reference blocks
- Component: A CRDT piece that can be composed with other segments into a block
  - Not CRDT yet, right now it just requires that if operations A B C D have been applied, if D C B
    are unapplied, F is inserted, and B C D are reapplied it should preserve user intent.

  
# TODO

- [ ] Idempotency. A client needs to be able to send the same operation multiple times without it being applied multiple times.