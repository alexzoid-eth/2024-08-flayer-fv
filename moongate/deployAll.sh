#!/bin/zsh
source .env && forge script ./script/DeployAll.s.sol --broadcast --private-key $DEV_PRIVATE_KEY -vvv