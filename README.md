
# Flayer contest details

- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the issue page in your private contest repo (label issues as med or high)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)

# Q&A

### Q: On what chains are the smart contracts going to be deployed?
# Flayer
For the purposes of this audit, we will only consider Base as the target network.

# Moongate
Ethereum mainnet and any number of EVM-compatible L2 chains.

___

### Q: If you are integrating tokens, are you allowing only whitelisted tokens to work with the codebase or any complying with the standard? Are they assumed to have certain properties, e.g. be non-reentrant? Are there any types of [weird tokens](https://github.com/d-xo/weird-erc20) you want to integrate?
# Flayer
Only support for tokens with the ERC721 standard will be supported for collections. These will be fractionalised into a standardised CollectionToken.

# Moongate
ERC721 and ERC1155 tokens will be supported. Additionally, the subset of those tokens that implement ERC-2981 for royalties will gain additional support for claiming.

___

### Q: Are there any limitations on values set by admins (or other roles) in the codebase, including restrictions on array lengths?
# Flayer
No expected limitations, it should just be assumed that initialized addresses in the contracts as set correctly.

# MoonGate
No expected limitations, it should just be assumed that initialized addresses in the contracts as set correctly.

___

### Q: Are there any limitations on values set by admins (or other roles) in protocols you integrate with, including restrictions on array lengths?
# Flayer
We should assume that contract references are set logically and correctly.

It should be assumed that `LinearRangeCurve` is approved by SudoSwap for usage on their external protocol.

# MoonGate
n/a

___

### Q: For permissioned functions, please list all checks and requirements that will be made before calling the function.
The following contracts will be added as LockerManager:
- Listings.sol
- ProtectedListings.sol
- CollectionShutdown.sol

```
LockerManager(lockerManager).setManager(listings, true);
LockerManager(lockerManager).setManager(protectedListings, true);
LockerManager(lockerManager).setManager(collectionShutdown, true);
```
___

### Q: Is the codebase expected to comply with any EIPs? Can there be/are there any deviations from the specification?
# Flayer
The CollectionToken should be strictly compliant with EIP-20

# Moongate
The Bridged721 should be strictly  compliant with EIP-721 and EIP-2981
The Bridged1155 should be strictly  compliant with EIP-1155 and EIP-2981
___

### Q: Are there any off-chain mechanisms or off-chain procedures for the protocol (keeper bots, arbitrage bots, etc.)?
# Flayer
No

# Moongate
No

___

### Q: Are there any hardcoded values that you intend to change before (some) deployments?
# Flayer
For FlayerTokenMigration.sol, the `nftxRatio` and `floorRatio` values will change before deployment.

# Moongate
No

___

### Q: If the codebase is to be deployed on an L2, what should be the behavior of the protocol in case of sequencer issues (if applicable)? Should Sherlock assume that the Sequencer won't misbehave, including going offline?
# Flayer
There shouldn’t be any issue for Flayer as token migration would happen externally to the desired protocol logic. We can assume for this that the Sequencer won’t misbehave or go offline.

# Moongate
We would assume that the Sequencer won’t misbehave, but if we can consider the implication of what would happen to bridged assets that are “isolated” on an L2 due to a Sequencer issue.

___

### Q: Should potential issues, like broken assumptions about function behavior, be reported if they could pose risks in future integrations, even if they might not be an issue in the context of the scope? If yes, can you elaborate on properties/invariants that should hold?
# Flayer
Responses such as expected fees and tax calculations should be correct for external protocols to utilise. It is also important that each NFT has a correct status. Having tokens that aren’t held by Flayer listed as for sale, protected listings missing, etc. would be detrimental.

# Moongate
I don’t think this needs to be checked.

___

### Q: Please discuss any design choices you made.
# Flayer
Via the Uniswap V4 hook we capture non-ETH fees and put them into an Internal Swap Pool. This means that LPs won’t receive the token straight away, but it will instead “frontrun” Uniswap swaps later on and convert out internal pool balances to an ETH-equivalent. These are then distributed to LPs in a more beneficial currency via the `donate` function.

# Moongate
When setting and claiming fees migrating to L2, we apply a blanket fee detection against the `0` token ID. This means that more complex royalty setups that vary per token will have a different value blanket royalty applied across all tokens on L2.

___

### Q: Please list any known issues and explicitly state the acceptable risks for each known issue.
# Flayer
Previous audits should already be remediated.

# Moongate
n/a

___

### Q: We will report issues where the core protocol functionality is inaccessible for at least 7 days. Would you like to override this value?
# Flayer
7 days is sufficient

# Moongate
7 days is sufficient

___

### Q: Please provide links to previous audits (if any).
# Flayer
n/a

# Moongate
n/a

___

### Q: Please list any relevant protocol resources.
# Flayer
The whitepaper for the protocol:
https://www.flayer.io/whitepaper

# Moongate
Built on top of the Optimism bridge. Source files can be found here for reference:
https://github.com/ethereum-optimism/optimism/tree/develop/packages/contracts-bedrock/src
___



# Audit scope


[flayer @ 6deb7863af19dd679c5638c299eb96a89626d455](https://github.com/flayerlabs/flayer/tree/6deb7863af19dd679c5638c299eb96a89626d455)
- [flayer/src/contracts/CollectionToken.sol](flayer/src/contracts/CollectionToken.sol)
- [flayer/src/contracts/Listings.sol](flayer/src/contracts/Listings.sol)
- [flayer/src/contracts/Locker.sol](flayer/src/contracts/Locker.sol)
- [flayer/src/contracts/LockerManager.sol](flayer/src/contracts/LockerManager.sol)
- [flayer/src/contracts/ProtectedListings.sol](flayer/src/contracts/ProtectedListings.sol)
- [flayer/src/contracts/TaxCalculator.sol](flayer/src/contracts/TaxCalculator.sol)
- [flayer/src/contracts/TokenEscrow.sol](flayer/src/contracts/TokenEscrow.sol)
- [flayer/src/contracts/implementation/BaseImplementation.sol](flayer/src/contracts/implementation/BaseImplementation.sol)
- [flayer/src/contracts/implementation/UniswapImplementation.sol](flayer/src/contracts/implementation/UniswapImplementation.sol)
- [flayer/src/contracts/lib/LinearRangeCurve.sol](flayer/src/contracts/lib/LinearRangeCurve.sol)
- [flayer/src/contracts/utils/AirdropRecipient.sol](flayer/src/contracts/utils/AirdropRecipient.sol)
- [flayer/src/contracts/utils/CollectionShutdown.sol](flayer/src/contracts/utils/CollectionShutdown.sol)
- [flayer/src/interfaces/Enums.sol](flayer/src/interfaces/Enums.sol)

[moongate @ d994cfed5a6f719dcde21a45acf22687b1df0e49](https://github.com/flayerlabs/moongate/tree/d994cfed5a6f719dcde21a45acf22687b1df0e49)
- [moongate/src/InfernalRiftAbove.sol](moongate/src/InfernalRiftAbove.sol)
- [moongate/src/InfernalRiftBelow.sol](moongate/src/InfernalRiftBelow.sol)
- [moongate/src/libs/ERC1155Bridgable.sol](moongate/src/libs/ERC1155Bridgable.sol)
- [moongate/src/libs/ERC721Bridgable.sol](moongate/src/libs/ERC721Bridgable.sol)




[flayer @ 6deb7863af19dd679c5638c299eb96a89626d455](https://github.com/flayerlabs/flayer/tree/6deb7863af19dd679c5638c299eb96a89626d455)
- [flayer/src/contracts/CollectionToken.sol](flayer/src/contracts/CollectionToken.sol)
- [flayer/src/contracts/Listings.sol](flayer/src/contracts/Listings.sol)
- [flayer/src/contracts/Locker.sol](flayer/src/contracts/Locker.sol)
- [flayer/src/contracts/LockerManager.sol](flayer/src/contracts/LockerManager.sol)
- [flayer/src/contracts/ProtectedListings.sol](flayer/src/contracts/ProtectedListings.sol)
- [flayer/src/contracts/TaxCalculator.sol](flayer/src/contracts/TaxCalculator.sol)
- [flayer/src/contracts/TokenEscrow.sol](flayer/src/contracts/TokenEscrow.sol)
- [flayer/src/contracts/implementation/BaseImplementation.sol](flayer/src/contracts/implementation/BaseImplementation.sol)
- [flayer/src/contracts/implementation/UniswapImplementation.sol](flayer/src/contracts/implementation/UniswapImplementation.sol)
- [flayer/src/contracts/lib/LinearRangeCurve.sol](flayer/src/contracts/lib/LinearRangeCurve.sol)
- [flayer/src/contracts/utils/AirdropRecipient.sol](flayer/src/contracts/utils/AirdropRecipient.sol)
- [flayer/src/contracts/utils/CollectionShutdown.sol](flayer/src/contracts/utils/CollectionShutdown.sol)
- [flayer/src/interfaces/Enums.sol](flayer/src/interfaces/Enums.sol)

