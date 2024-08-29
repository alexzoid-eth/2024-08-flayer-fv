# Subgraph Planning

## Constants

```
/// Minimum and maximum liquid listing durations
uint32 MIN_LIQUID_DURATION = 7 days;
uint32 MAX_LIQUID_DURATION = 180 days;

/// Minimum and maximum dutch listing durations
uint32 public constant MIN_DUTCH_DURATION = 1 days;
uint32 public constant MAX_DUTCH_DURATION = 7 days - 1;

/// The amount that a Keeper will receive when a protected listing that liquidated and
/// subsequently sold is given from the sale. A keeper is the address that triggers the
/// protected listing to liquidate.
uint KEEPER_REWARD = 0.05 ether;

/// The maximum amount that a user can claim against their protected listing
uint MAX_PROTECTED_TOKEN_AMOUNT = 1 ether - KEEPER_REWARD;

/// The utilization rate at which protected listings will rapidly increase APR
uint UTILIZATION_KINK = 0.8 ether;
```

## Entities

### Config

```
Config {
  /// Prevents fee distribution to Uniswap V4 pools below a certain threshold. Updated
  /// via DonateThresholdsUpdated(_donateThresholdMin, _donateThresholdMax).
  uint donateThresholdMin = 0.001 ether;
  uint donateThresholdMax = 0.1 ether;

  /// A global AMM fee can be set across all collection pools. When AMM fees are captured
  /// we additionally emit an event, but currently we don't track it (?):
  /// `UniswapImplementation.AMMFeesTaken(address _recipient, address _token, uint _amount)`
  /// The recipient of `AMMFeesTaken` may be address(0), which shows it burnt the token

  uint24 ammFee = 0; // Set by `UniswapImplementation.AMMFeeSet`
  address ammBeneficiary = address(0); // Set by `UniswapImplementation.AMMBeneficiarySet`

  /// If the {Locker} is paused then we will need to lock down functionality of
  /// the platform on the frontend to reflect this. Updated via Locker.Paused and
  /// Locker.Unpaused.
  bool locked = false;
}
```

### Collections

```
Collection {
  // Information set when token is initialized via Locker.CollectionCreated
  bytes32 id (address);
  address collection;
  address collectionToken;

  // The denomination of the {CollectionToken}
  uint denomination;

  // The user that triggered the creation of the collection on Flayer
  address creator;

  // This will be a bytes value for our pool implementation. This will be sent by the `Locker.CollectionInitialized`
  // event and is the `_poolKey` value.
  bytes poolKey;

  // This is set when initialized, or via CollectionToken.MetadataUpdated
  string name;
  string symbol;

  // Linked array of listings for the collection
  Listing[] listings;

  // Pending and lifetime pool fees earned
  PoolFees poolFees;

  // Information on where the collection was bridged from:
  // https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/L2/L2ERC721Bridge.sol
  // https://github.com/ethereum-optimism/optimism/blob/develop/packages/contracts-bedrock/src/universal/OptimismMintableERC721.sol
  uint sourceChainId;
  address sourceChainAddress;

  // The pool fee that has been set by `BaseImplementation.DefaultFeeSet` or `BaseImplementation.PoolFeeSet`. The `poolFee`
  // will overwrite the `defaultFee` on the frontend as this will be used if set.
  uint defaultFee;
  uint poolFee;

  // We can store the latest sqrtPriceX96 for the pool to allow us to determine the swap price. This is
  // initially set by `Locker.CollectionInitialized` and will be updated by `BaseImplementation.PoolStateUpdated`.
  int sqrtPriceX96;

  // Keeps track of the number of listings that are created for a collection. This can be used to help calculate
  // utilization rates on the frontend and show the number of listings available. Refer to [Note 1] for information
  // on events and actions that will modify these values.
  uint publicListings;
  uint protectedListings;

  // Checks if shutdown calls are prevented for the collection. This will be false by default, and is triggered
  // by `CollectionShutdownPrevention(_collection, _prevent)`.
  bool shutdownPrevented;
}
```


### Listing

A listing is created with `Listings.ListingsCreated` and deleted with `ListingsFilled`, `ListingsCancelled` or `ListingUnlocked`.

If the "listing" is created with `Locker.TokenDeposit`, then this is a floor listing and it will vary from the above as it
won't have an owner, duration, floorMultiple or protected value. This will mean that these should support either `NULL` values
or be able to be set to a zero value. `Locker.TokenRedeem` will remove the listing.

Another method of floor item creation will be `Locker.TokenSwap` or `Locker.TokenSwapBatch` as these will remove
the existing Listing and create a new one in it's place.

```
Listing {
  // Unique identifier based on the collection and tokenId (no ERC1155 support)
  bytes32 id (collection - tokenId);

  // Token listing information
  Collection collection
  uint tokenId;

  // Information regarding the listing updated in:
  // - ListingRelisted (may change all)
  // - ListingTransferred (changes owner)
  // - ListingExtended (changes created and duration)
  // - ListingFloorMultipleUpdated (changes floor multiple)
  address owner;
  uint40 created;
  uint32 duration;
  uint16 floorMultiple;
  bool protected;

  // Determined format set based on a range of events. There is more description of how this
  // is set in Listings.getListingType(). If the floorMultiple is zero, then this is a floor
  // item and will therefore have a `NONE` format.
  //
  // There will also be a variation at which the `duration` has expired from the `created` time
  // and this would mean that it would be `LIQUID` in the subgraph, but `DUTCH` on the frontend.
  // This isn't a problem, but may just be confusing at first glance.
  enum format; // (NONE, DUTCH, LIQUID, PROTECTED)

  // The amount of tax that has been paid against the listing _and_ has been distributed to
  // our `FeeCollector` equivalent. This value should be set to zero when `Listings.ListingsCreated`
  // is triggered and then we can increment this value whenever we get `Listings.ListingFeeCaptured`.
  //
  // Frontend needs to know:
  // - Total tax paid against a listing that has been locked / captured
  // - The rest of the taxes would be able to be calculated by a web3 call so I don't think we
  //   need to focus on any of this from a subgraph perspective.
  uint taxCaptured;

  // Protected specific information. The keeper is set with ProtectedListingLiquidated. The
  // value of tokenTaken is set and updated via ListingDebtAdjusted.
  address keeper;
  uint96 tokenTaken;
  uint checkpointIndex;
}
```


### ListingActivity

```
ListingActivity {
  // Unique identifier
  bytes32 id (collection - tokenId - type - timestamp)

  // The listing that it relates to based on collection + tokenId
  Listing listing;

  // The type of the activity, determined by where the event came from
  // CREATED     - ListingsCreated (array of created listings), Locker.TokenDeposit, Locker.TokenSwap or Locker.TokenSwapBatch
  // RELISTED    - ListingRelisted
  // FILLED      - ListingsFilled, Locker.TokenSwap or Locker.TokenSwapBatch
  // TRANSFERRED - ListingTransferred (owner changed)
  // CANCELLED   - ListingsCancelled
  // EXTENDED    - ListingExtended (duration increased)
  // ADJUSTED    - ListingDebtAdjusted (borrow or repay from protected)
  // UNLOCKED    - ListingUnlocked (protected listing is repayed + released)
  // LIQUIDATED  - ProtectedListingLiquidated (protected listing turned dutch)
  // REPRICED    - ListingFloorMultipleUpdated (price updated)
  enum type;

  // Transaction hash that created the activity
  string txHash;

  // Transaction specific variables that are optional, depending on event type
  address from;
  address to;

  // Q: Do we need to store all the changes in here? If so, should we implement some kind
  // of abstracted "old -> new" field, rather than explicit?
  uint floorMultiple;
  uint ethPrice;

  // The timestamp that the transaction was created
  uint created;
}
```


### LockerManager

```
LockerManager {
  // Unique identifier based on the address of the manager approved. Created and deleted
  // with Locker.ManagerSet based on the `approved` bool value.
  bytes id;

  // Address of the contract that has been approved
  address manager;
}
```


### TokenEscrow

```
TokenEscrow {
  // Unique identifier based on the recipient (payee) address
  bytes id (payee);

  // The address of the payee / recipient
  address payee;

  // The amount of token available. This entity will either be created by TokenEscrow.Deposit and
  // the amount value will be updated by both TokenEscrow.Deposit and TokenEscrow.Withdrawal.
  uint amount;

  // When the last deposit was made
  uint updated;
}
```


### PoolFees

```
PoolFees {
  // Unique identifier based on the collection address
  bytes id (collection);

  // The collection that this PoolId is linked to
  Collection collection;

  // The amount of token0 and token1 that is currently available. The will be incremented by
  // `FeeCollector.PoolFeesReceived` and decremented by `FeeCollector.PoolFeesDistributed`.
  //
  // The `tokenAvailable` amount will gradually be converted by hooking into swaps. When this
  // happens, we will receive a `FeeCollector.PoolFeesSwapped` event that will show the number
  // of tokens that were taken from `tokenAvailable` and added to `ethAvailable`.
  uint ethAvailable;
  uint tokenAvailable;

  // The amount of token0 and token1 that has been added from all time. The will be
  // incremented by `BaseImplementation.PoolFeesReceived`.
  uint totalEthOut;
  uint totalTokenIn;
}
```


### PoolFeeDistributions

```
PoolFeeDistributions {
  // Unique identifier based on the PoolId and the timestamp at which the tx took
  // place. This will be created by FeeCollector.PoolFeesDistributed.
  bytes id (collection - timestamp);

  // The collection that this distribution relates to
  Collection collection;

  // The amounts of ETH and token distributed to the pool
  uint ethDistributed;
  uint tokenDistributed;

  // The transaction hash of the distribution
  string txHash;

  // The user that triggered the transaction
  address triggeredBy;

  // The timestamp that this distribution was made
  uint created;
}
```


### Beneficiary

```
Beneficiary {
  // Unique identifier based on the address of the beneficiary. This record should
  // be created with FeeCollector.BeneficiaryUpdated.
  bytes id (address);

  // An array of tokens that are available to claim for a beneficiary.
  BeneficiaryFee claimable[];
}
```


### BeneficiaryFee

```
BeneficiaryFee {
  // Unique identifier based on the beneficiary and token address. This record should
  // be created or updated with FeeCollector.BeneficiaryFeesReceived.
  bytes id (beneficiary - token)

  // Store the beneficiary based on their address
  Beneficiary beneficiary;

  // The token that is claimable
  address token;

  // The amount of token available. This will be incremented with
  // FeeCollector.BeneficiaryFeesReceived and decremented with
  // FeeCollector.BeneficiaryFeesClaimed.
  uint available;
```


### CollectionShutdown

Note: The call to know when a claim can be made must be an onchain call. We don't receive a notification
that we can push out to the Subgraph for this. This shutdown can be cancelled and removed when
`CollectionShutdownCancelled(_collection)` is called.

```
CollectionShutdown {
  // Unique identifier, created by CollectionShutdown.CollectionShutdownStarted
  bytes id (Collection address);

  // The collection being shutdown
  Collection collection;

  // An array of the votes made for the shutdown
  CollectionShutdownVote[] votes;

  // The amount required to reach quorum
  uint quorum;

  // The sudoswap liquidation pool address that will be created by `CollectionShutdownExecuted`
  address liquidationPool;
  uint[] liquidationPoolTokens;

  // This value should be incremented by `CollectionShutdownTokenLiquidated`
  uint claimAvailable;

  // When the shutdown was started, and whom it was started by
  uint startedAt;
  address startedBy;

  // When the shutdown was started, and whom it was started by
  uint executedAt;
  address executedBy;

  // The timestamp that the shutdown reached / surpassed quorum. Updated via
  // CollectionShutdownQuorumReached. If this has a timestamp value, then we know
  // that it can be executed.
  uint quorumReachedAt;
}
```


### CollectionShutdownVote

A vote record will be created by either a CollectionShutdownVote or CollectionShutdownVoteReclaim event. The
different will be that a `CollectionShutdownVote` will imply a positive `votes` value, and `CollectionShutdownVoteReclaim`
will imply a negative `votes` value. Note, however, that both of these events will send a positive value that will
need to be inverted accordingly.

```
CollectionShutdownVote {
  // A unique identifier for when a user casts their vote
  bytes id (Collection address - voter - index);

  // The CollectionShutdown that this relates to
  CollectionShutdown collectionShutdown;

  // Information about the vote
  address voter;
  int votes;

  // The timestamp that the vote was placed
  uint createdAt;
}
```


### CollectionShutdownClaim

```
CollectionShutdownClaim {
  // Unique identifier for when the voter makes a claim. This is created by `CollectionShutdownClaim`
  bytes id (Collection address - voter - index);

  // The CollectionShutdown that this relates to
  CollectionShutdown collectionShutdown;

  // The claim related information
  address claimant;
  uint tokensBurnt;
  uint ethReceived;

  // The transaction hash
  string tx;

  // The timestamp that the user made their claim
  uint claimedAt;
}
```


### AirdropDistribution

```
AirdropDistribution {
  // Unique identifier based on airdrop information, created by `AirdropRecipient.AirdropDistributed`
  bytes id (_merkle - _claimType);

  // Basic airdrop information
  bytes32 merkle;
  enum claimType; // ERC20, ERC721, ERC1155, NATIVE

  // An array of all related claims
  AirdropClaim[] claims;

  // The timestamp that the tx was created
  uint claimedAt;
}
```


### AirdropClaim

```
AirdropClaim {
  // Unique identifier created by `AirdropRecipient.AirdropClaimed`.
  bytes id (recipient - tokenId - amount - timestamp);

  // The airdrop that this relates to
  AirdropDistribution airdrop;

  // Data extracted from the MerkleClaim struct
  address recipient;
  address target;
  uint tokenId;
  uint amount;

  // The transaction hash
  string tx;

  // The timestamp that the tx was created
  uint claimedAt;
}
```

### Checkpoint

For the calculation of compound interest in `ProtectedListings` we take a series of `Checkpoint`s that
then are used to determine the end result. I don't believe there is a current frontend need for this
information, but maybe better to capture it.

```
Checkpoint {
  // Unique identifier created by `ProtectedListings.CheckpointCreated`.
  bytes id (collection - index);

  address collection;
  uint index;

  // The information for the next fields can be sourced from the contract call
  // `ProtectedListings.collectionCheckpoints(collection, index)`, but we can update the event
  // if preferred.
  uint compoundedFactor;
  uint timestamp;
}
```


### [Note 1]: Monitoring Listing Type Updates

The following events will update the listing types as displayed:

```
emit ListingUnlocked   = -1 protected
emit ListingRelisted   = -1 old listing, +1 new listing
emit ListingsCancelled = -x liquid
emit ListingsFilled    = -1 of each listing type
```

For `ListingRelisted` and `ListingsFilled`, we would need to know the type of each listing that is filled, whereas the others
have set types. We should be able to cross check these against the existing `Listing` objects in the subgraph.
