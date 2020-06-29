pragma solidity ^0.5.0;

import "./OneSplitBase.sol";
import "./interface/IBFactory.sol";
import "./interface/IBPool.sol";


contract OneSplitBalancerPoolTokenBase {
    using SafeMath for uint256;

    uint internal constant BONE = 10**18;

    // todo: factory for Bronze release
    // may be changed in future
    IBFactory bFactory = IBFactory(0x9424B1412450D0f8Fc2255FAf6046b98213B76Bd);

    struct TokenWithWeight {
        IERC20 token;
        uint256 reserveBalance;
        uint256 denormalizedWeight;
    }

    struct PoolTokenDetails {
        TokenWithWeight[] tokens;
        uint256 totalWeight;
        uint256 totalSupply;
    }

    function _getPoolDetails(IBPool poolToken)
        internal
        view
        returns (PoolTokenDetails memory details)
    {
        address[] memory currentTokens = poolToken.getCurrentTokens();
        details.tokens = new TokenWithWeight[](currentTokens.length);
        details.totalWeight = poolToken.getTotalDenormalizedWeight();
        details.totalSupply = poolToken.totalSupply();
        for (uint256 i = 0; i < details.tokens.length; i++) {
            details.tokens[i].token = IERC20(currentTokens[i]);
            details.tokens[i].denormalizedWeight = poolToken.getDenormalizedWeight(currentTokens[i]);
            details.tokens[i].reserveBalance = poolToken.getBalance(currentTokens[i]);
        }
    }

    function _calcPoolOutAmount(
        uint256 tokenAmount,
        uint256 reserve,
        uint256 totalSupply
    )
        internal
        pure
        returns (uint256)
    {
        uint256 ratio = bdiv(tokenAmount, reserve);
        return bmul(ratio, totalSupply);
    }

    function bdiv(uint256 a, uint256 b) internal pure returns (uint256) {
        require(b != 0, "ERR_DIV_ZERO");
        uint c0 = a * BONE;
        require(a == 0 || c0 / a == BONE, "ERR_DIV_INTERNAL"); // bmul overflow
        uint c1 = c0 + (b / 2);
        require(c1 >= c0, "ERR_DIV_INTERNAL"); //  badd require
        uint c2 = c1 / b;
        return c2;
    }

    function bmul(uint a, uint b) internal pure returns (uint) {
        uint c0 = a * b;
        require(a == 0 || c0 / a == b, "ERR_MUL_OVERFLOW");
        uint c1 = c0 + (BONE / 2);
        require(c1 >= c0, "ERR_MUL_OVERFLOW");
        uint c2 = c1 / BONE;
        return c2;
    }
}


contract OneSplitBalancerPoolTokenView is OneSplitViewWrapBase, OneSplitBalancerPoolTokenBase {

    function getExpectedReturnWithGas(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 amount,
        uint256 parts,
        uint256 flags,
        uint256 destTokenEthPriceTimesGasPrice
    )
        public
        view
        returns(
            uint256,
            uint256,
            uint256[] memory
        )
    {
        if (fromToken == toToken) {
            return (amount, 0, new uint256[](DEXES_COUNT));
        }


        if (!flags.check(FLAG_DISABLE_BALANCER_POOL_TOKEN)) {
            bool isPoolTokenFrom = bFactory.isBPool(address(fromToken));
            bool isPoolTokenTo = bFactory.isBPool(address(toToken));

            if (isPoolTokenFrom && isPoolTokenTo) {
                (
                    uint256 returnETHAmount,
                    uint256[] memory poolTokenFromDistribution
                ) = _getExpectedReturnFromBalancerPoolToken(
                    fromToken,
                    ETH_ADDRESS,
                    amount,
                    parts,
                    FLAG_DISABLE_BALANCER_POOL_TOKEN
                );

                (
                    uint256 returnPoolTokenToAmount,
                    uint256[] memory poolTokenToDistribution
                ) = _getExpectedReturnToBalancerPoolToken(
                    ETH_ADDRESS,
                    toToken,
                    returnETHAmount,
                    parts,
                    FLAG_DISABLE_BALANCER_POOL_TOKEN
                );

                for (uint i = 0; i < poolTokenToDistribution.length; i++) {
                    poolTokenFromDistribution[i] |= poolTokenToDistribution[i] << 128;
                }

                return (returnPoolTokenToAmount, 0, poolTokenFromDistribution);
            }

            if (isPoolTokenFrom) {
                (uint256 returnAmount, uint256[] memory dist) = _getExpectedReturnFromBalancerPoolToken(
                    fromToken,
                    toToken,
                    amount,
                    parts,
                    FLAG_DISABLE_BALANCER_POOL_TOKEN
                );
                return (returnAmount, 0, dist);
            }

            if (isPoolTokenTo) {
                (uint256 returnAmount, uint256[] memory dist) = _getExpectedReturnToBalancerPoolToken(
                    fromToken,
                    toToken,
                    amount,
                    parts,
                    FLAG_DISABLE_BALANCER_POOL_TOKEN
                );
                return (returnAmount, 0, dist);
            }
        }

        return super.getExpectedReturnWithGas(
            fromToken,
            toToken,
            amount,
            parts,
            flags,
            destTokenEthPriceTimesGasPrice
        );
    }

    function _getExpectedReturnFromBalancerPoolToken(
        IERC20 poolToken,
        IERC20 toToken,
        uint256 amount,
        uint256 parts,
        uint256 flags
    )
        private
        view
        returns (
            uint256 returnAmount,
            uint256[] memory distribution
        )
    {
        distribution = new uint256[](DEXES_COUNT);

        IBPool bToken = IBPool(address(poolToken));
        address[] memory currentTokens = bToken.getCurrentTokens();

        uint256 pAiAfterExitFee = amount.sub(
            amount.mul(bToken.EXIT_FEE())
        );
        uint256 ratio = bdiv(pAiAfterExitFee, poolToken.totalSupply());
        for (uint i = 0; i < currentTokens.length; i++) {
            uint256 tokenAmountOut = bmul(ratio, bToken.getBalance(currentTokens[i]));

            if (currentTokens[i] == address(toToken)) {
                returnAmount = returnAmount.add(tokenAmountOut);
                continue;
            }

            (uint256 ret, ,uint256[] memory dist) = super.getExpectedReturnWithGas(
                IERC20(currentTokens[i]),
                toToken,
                tokenAmountOut,
                parts,
                flags,
                0
            );

            returnAmount = returnAmount.add(ret);

            for (uint j = 0; j < distribution.length; j++) {
                distribution[j] |= dist[j] << (i * 8);
            }
        }

        return (returnAmount, distribution);
    }

    function _getExpectedReturnToBalancerPoolToken(
        IERC20 fromToken,
        IERC20 poolToken,
        uint256 amount,
        uint256 parts,
        uint256 flags
    )
        private
        view
        returns (
            uint256 minFundAmount,
            uint256[] memory distribution
        )
    {
        distribution = new uint256[](DEXES_COUNT);
        minFundAmount = uint256(-1);

        PoolTokenDetails memory details = _getPoolDetails(IBPool(address(poolToken)));

        uint256[] memory dist;
        uint256 tokenAmount;
        uint256 fundAmount;

        for (uint i = 0; i < details.tokens.length; i++) {
            uint256 exchangeAmount = amount.mul(
                details.tokens[i].denormalizedWeight
            ).div(details.totalWeight);

            if (details.tokens[i].token != fromToken) {
                (tokenAmount, ,dist) = this.getExpectedReturnWithGas(
                    fromToken,
                    details.tokens[i].token,
                    exchangeAmount,
                    parts,
                    flags,
                    0
                );

                for (uint j = 0; j < distribution.length; j++) {
                    distribution[j] |= dist[j] << (i * 8);
                }
            } else {
                tokenAmount = exchangeAmount;
            }

            fundAmount = _calcPoolOutAmount(
                tokenAmount,
                details.tokens[i].reserveBalance,
                details.totalSupply
            );

            if (fundAmount < minFundAmount) {
                minFundAmount = fundAmount;
            }
        }

        //        uint256 _minFundAmount = minFundAmount;
        //        uint256 swapFee = IBPool(address(poolToken)).getSwapFee();
        // Swap leftovers for PoolToken
        //        for (uint i = 0; i < details.tokens.length; i++) {
        //            if (_minFundAmount == fundAmounts[i]) {
        //                continue;
        //            }
        //
        //            uint256 leftover = tokenAmounts[i].sub(
        //                fundAmounts[i].mul(details.tokens[i].reserveBalance).div(details.totalSupply)
        //            );
        //
        //            uint256 tokenRet = IBPool(address(poolToken)).calcPoolOutGivenSingleIn(
        //                details.tokens[i].reserveBalance,
        //                details.tokens[i].denormalizedWeight,
        //                details.totalSupply,
        //                details.totalWeight,
        //                leftover,
        //                swapFee
        //            );
        //
        //            minFundAmount = minFundAmount.add(tokenRet);
        //        }

        return (minFundAmount, distribution);
    }

}


contract OneSplitBalancerPoolToken is OneSplitBaseWrap, OneSplitBalancerPoolTokenBase {
    function _swap(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 amount,
        uint256[] memory distribution,
        uint256 flags
    ) internal {
        if (fromToken == toToken) {
            return;
        }

        if (!flags.check(FLAG_DISABLE_BALANCER_POOL_TOKEN)) {
            bool isPoolTokenFrom = bFactory.isBPool(address(fromToken));
            bool isPoolTokenTo = bFactory.isBPool(address(toToken));

            if (isPoolTokenFrom && isPoolTokenTo) {
                uint256[] memory dist = new uint256[](distribution.length);
                for (uint i = 0; i < distribution.length; i++) {
                    dist[i] = distribution[i] & ((1 << 128) - 1);
                }

                uint256 ethBalanceBefore = address(this).balance;

                _swapFromBalancerPoolToken(
                    fromToken,
                    ETH_ADDRESS,
                    amount,
                    dist,
                    FLAG_DISABLE_BALANCER_POOL_TOKEN
                );

                for (uint i = 0; i < distribution.length; i++) {
                    dist[i] = distribution[i] >> 128;
                }

                uint256 ethBalanceAfter = address(this).balance;

                return _swapToBalancerPoolToken(
                    ETH_ADDRESS,
                    toToken,
                    ethBalanceAfter.sub(ethBalanceBefore),
                    dist,
                    FLAG_DISABLE_BALANCER_POOL_TOKEN
                );
            }

            if (isPoolTokenFrom) {
                return _swapFromBalancerPoolToken(
                    fromToken,
                    toToken,
                    amount,
                    distribution,
                    FLAG_DISABLE_BALANCER_POOL_TOKEN
                );
            }

            if (isPoolTokenTo) {
                return _swapToBalancerPoolToken(
                    fromToken,
                    toToken,
                    amount,
                    distribution,
                    FLAG_DISABLE_BALANCER_POOL_TOKEN
                );
            }
        }

        return super._swap(
            fromToken,
            toToken,
            amount,
            distribution,
            flags
        );
    }

    function _swapFromBalancerPoolToken(
        IERC20 poolToken,
        IERC20 toToken,
        uint256 amount,
        uint256[] memory distribution,
        uint256 flags
    ) private {

        IBPool bToken = IBPool(address(poolToken));

        address[] memory currentTokens = bToken.getCurrentTokens();

        uint256[] memory minAmountsOut = new uint256[](currentTokens.length);
        for (uint i = 0; i < currentTokens.length; i++) {
            minAmountsOut[i] = 1;
        }

        bToken.exitPool(amount, minAmountsOut);

        uint256[] memory dist = new uint256[](distribution.length);
        for (uint i = 0; i < currentTokens.length; i++) {

            if (currentTokens[i] == address(toToken)) {
                continue;
            }

            for (uint j = 0; j < distribution.length; j++) {
                dist[j] = (distribution[j] >> (i * 8)) & 0xFF;
            }

            uint256 exchangeTokenAmount = IERC20(currentTokens[i]).balanceOf(address(this));

            super._swap(
                IERC20(currentTokens[i]),
                toToken,
                exchangeTokenAmount,
                dist,
                flags
            );
        }

    }

    function _swapToBalancerPoolToken(
        IERC20 fromToken,
        IERC20 poolToken,
        uint256 amount,
        uint256[] memory distribution,
        uint256 flags
    ) private {
        uint256[] memory dist = new uint256[](distribution.length);
        uint256 minFundAmount = uint256(-1);

        PoolTokenDetails memory details = _getPoolDetails(IBPool(address(poolToken)));

        uint256[] memory maxAmountsIn = new uint256[](details.tokens.length);
        uint256 curFundAmount;
        for (uint i = 0; i < details.tokens.length; i++) {
            uint256 exchangeAmount = amount
                .mul(details.tokens[i].denormalizedWeight)
                .div(details.totalWeight);

            if (details.tokens[i].token != fromToken) {
                for (uint j = 0; j < distribution.length; j++) {
                    dist[j] = (distribution[j] >> (i * 8)) & 0xFF;
                }

                super._swap(
                    fromToken,
                    details.tokens[i].token,
                    exchangeAmount,
                    dist,
                    flags
                );

                curFundAmount = _calcPoolOutAmount(
                    details.tokens[i].token.balanceOf(address(this)),
                    details.tokens[i].reserveBalance,
                    details.totalSupply
                );
            } else {
                curFundAmount = _calcPoolOutAmount(
                    exchangeAmount,
                    details.tokens[i].reserveBalance,
                    details.totalSupply
                );
            }

            if (curFundAmount < minFundAmount) {
                minFundAmount = curFundAmount;
            }

            maxAmountsIn[i] = uint256(-1);
            details.tokens[i].token.universalApprove(address(poolToken), uint256(- 1));
        }

        IBPool(address(poolToken)).joinPool(minFundAmount, maxAmountsIn);

        // Return leftovers
        for (uint i = 0; i < details.tokens.length; i++) {
            details.tokens[i].token.universalTransfer(msg.sender, details.tokens[i].token.balanceOf(address(this)));
        }
    }
}
