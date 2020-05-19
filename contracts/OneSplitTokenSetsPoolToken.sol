pragma solidity ^0.5.0;

import "./OneSplitBase.sol";
import "./interface/ITokenSet.sol";
import "./interface/ITokenSetsCore.sol";


contract OneSplitTokenSetsPoolTokenBase {
    using SafeMath for uint256;
    using UniversalERC20 for IERC20;

    ITokenSetsCore constant core = ITokenSetsCore(0xf55186CC537E7067EA616F2aaE007b4427a120C8);

    struct TokenSetDetails {
        IERC20[] tokens;
        uint256[] memory requiredComponentQuantities;
    }

    function _getPoolDetails(ITokenSet tokenSet, uint256 amount)
        internal
        view
        returns(TokenSetDetails memory details)
    {
        uint256[] memory units = tokenSet.getUnits();
        uint256 naturalUnit = tokenSet.naturalUnit();
        details.tokens = tokenSet.getComponents();
        details.requiredComponentQuantities = new uint256[](units.length);
        for (uint i = 0; i < units.length; i++) {
            details.requiredComponentQuantities[i] = amount.div(naturalUnit).mul(units[i]);
        }
    }
}


contract OneSplitTokenSetsPoolTokenView is OneSplitViewWrapBase, OneSplitTokenSetsPoolTokenBase {
    function getExpectedReturn(
        IERC20 fromToken,
        IERC20 toToken,
        uint256 amount,
        uint256 parts,
        uint256 flags
    )
        public
        view
        returns (
            uint256 returnAmount,
            uint256[] memory distribution
        )
    {
        if (fromToken == toToken) {
            return (amount, new uint256[](DEXES_COUNT));
        }


        if (!flags.check(FLAG_DISABLE_TOKEN_SETS_POOL_TOKEN)) {
            bool isPoolTokenFrom = core.validSets(fromToken);
            bool isPoolTokenTo = core.validSets(toToken);

            if (isPoolTokenFrom && isPoolTokenTo) {
                (
                    uint256 returnWETHAmount,
                    uint256[] memory poolTokenFromDistribution
                ) = _getExpectedReturnFromTokenSetsPoolToken(
                    fromToken,
                    weth,
                    amount,
                    parts,
                    FLAG_DISABLE_TOKEN_SETS_POOL_TOKEN
                );

                (
                uint256 returnPoolTokenToAmount,
                uint256[] memory poolTokenToDistribution
                ) = _getExpectedReturnToTokenSetsPoolToken(
                    weth,
                    toToken,
                    returnWETHAmount,
                    parts,
                    FLAG_DISABLE_TOKEN_SETS_POOL_TOKEN
                );

                for (uint i = 0; i < poolTokenToDistribution.length; i++) {
                    poolTokenFromDistribution[i] |= poolTokenToDistribution[i] << 128;
                }

                return (returnPoolTokenToAmount, poolTokenFromDistribution);
            }

            if (isPoolTokenFrom) {
                return _getExpectedReturnFromTokenSetsPoolToken(
                    fromToken,
                    toToken,
                    amount,
                    parts,
                    FLAG_DISABLE_TOKEN_SETS_POOL_TOKEN
                );
            }

            if (isPoolTokenTo) {
                return _getExpectedReturnToTokenSetsPoolToken(
                    fromToken,
                    toToken,
                    amount,
                    parts,
                    FLAG_DISABLE_TOKEN_SETS_POOL_TOKEN
                );
            }
        }

        return super.getExpectedReturn(
            fromToken,
            toToken,
            amount,
            parts,
            flags
        );
    }

    function _getExpectedReturnFromTokenSetsPoolToken(
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

        TokenSetDetails memory details = _getPoolDetails(ITokenSet(poolToken));
        for (uint i = 0; i < details.tokens; i++) {

            uint256 tokenAmountOut = curveInfo.curve.balances(int128(i))
                .mul(amount)
                .div(totalSupply);

            if (coin == toToken) {
                returnAmount = returnAmount.add(tokenAmountOut);
                continue;
            }

            (uint256 ret, uint256[] memory dist) = this.getExpectedReturn(
                coin,
                toToken,
                tokenAmountOut,
                parts,
                flags
            );

            returnAmount = returnAmount.add(ret);

            for (uint j = 0; j < distribution.length; j++) {
                distribution[j] |= dist[j] << (i * 8);
            }
        }

        return (returnAmount, distribution);
    }

    function _getExpectedReturnToTokenSetsPoolToken(
        IERC20 fromToken,
        IERC20 poolToken,
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

        CurveInfo memory curveInfo = _getCurve(poolToken);
        CurvePoolTokenDetails memory details = _getPoolDetails(
            curveInfo.curve,
            curveInfo.tokenCount
        );

        bytes memory tokenAmounts;
        for (uint i = 0; i < curveInfo.tokenCount; i++) {
            uint256 exchangeAmount = amount
                .mul(details.tokens[i].weightedReserveBalance)
                .div(details.totalWeightedBalance);

            if (details.tokens[i].token == fromToken) {
                tokenAmounts = abi.encodePacked(tokenAmounts, exchangeAmount);
                continue;
            }

            (uint256 tokenAmount, uint256[] memory dist) = this.getExpectedReturn(
                fromToken,
                details.tokens[i].token,
                exchangeAmount,
                parts,
                flags
            );

            tokenAmounts = abi.encodePacked(tokenAmounts, tokenAmount);

            for (uint j = 0; j < distribution.length; j++) {
                distribution[j] |= dist[j] << (i * 8);
            }
        }

        (bool success, bytes memory data) = address(curveInfo.curve).staticcall(
            abi.encodePacked(
                _getCurveCalcTokenAmountSelector(curveInfo.tokenCount),
                tokenAmounts,
                uint256(1)
            )
        );

        require(success, 'calc_token_amount failed');

        return (abi.decode(data, (uint256)), distribution);
    }
}


contract OneSplitCurvePoolToken is OneSplitBaseWrap, OneSplitTokenSetsPoolTokenBase {
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

        if (!flags.check(FLAG_DISABLE_CURVE_ZAP)) {
            if (_isPoolToken(fromToken)) {
                return _swapFromCurvePoolToken(
                    fromToken,
                    toToken,
                    amount,
                    distribution,
                    FLAG_DISABLE_CURVE_ZAP
                );
            }

            if (_isPoolToken(toToken)) {
                return _swapToCurvePoolToken(
                    fromToken,
                    toToken,
                    amount,
                    distribution,
                    FLAG_DISABLE_CURVE_ZAP
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

    function _swapFromCurvePoolToken(
        IERC20 poolToken,
        IERC20 toToken,
        uint256 amount,
        uint256[] memory distribution,
        uint256 flags
    ) private {
        CurveInfo memory curveInfo = _getCurve(poolToken);

        bytes memory minAmountsOut;
        for (uint i = 0; i < curveInfo.tokenCount; i++) {
            minAmountsOut = abi.encodePacked(minAmountsOut, uint256(1));
        }

        (bool success,) = address(curveInfo.curve).call(
            abi.encodePacked(
                _getCurveRemoveLiquiditySelector(curveInfo.tokenCount),
                amount,
                minAmountsOut
            )
        );

        require(success, 'remove_liquidity failed');

        uint256[] memory dist = new uint256[](distribution.length);
        for (uint i = 0; i < curveInfo.tokenCount; i++) {
            IERC20 coin = IERC20(curveInfo.curve.coins(int128(i)));

            if (coin == toToken) {
                continue;
            }

            for (uint j = 0; j < distribution.length; j++) {
                dist[j] = (distribution[j] >> (i * 8)) & 0xFF;
            }

            uint256 exchangeTokenAmount = coin.universalBalanceOf(address(this));

            this.swap(
                coin,
                toToken,
                exchangeTokenAmount,
                0,
                dist,
                flags
            );
        }
    }

    function _swapToCurvePoolToken(
        IERC20 fromToken,
        IERC20 poolToken,
        uint256 amount,
        uint256[] memory distribution,
        uint256 flags
    ) private {
        uint256[] memory dist = new uint256[](distribution.length);

        CurveInfo memory curveInfo = _getCurve(poolToken);
        CurvePoolTokenDetails memory details = _getPoolDetails(
            curveInfo.curve,
            curveInfo.tokenCount
        );

        bytes memory tokenAmounts;
        for (uint i = 0; i < curveInfo.tokenCount; i++) {
            uint256 exchangeAmount = amount
                .mul(details.tokens[i].weightedReserveBalance)
                .div(details.totalWeightedBalance);

            _infiniteApproveIfNeeded(details.tokens[i].token, address(curveInfo.curve));

            if (details.tokens[i].token == fromToken) {
                tokenAmounts = abi.encodePacked(tokenAmounts, exchangeAmount);
                continue;
            }

            for (uint j = 0; j < distribution.length; j++) {
                dist[j] = (distribution[j] >> (i * 8)) & 0xFF;
            }

            this.swap(
                fromToken,
                details.tokens[i].token,
                exchangeAmount,
                0,
                dist,
                flags
            );

            tokenAmounts = abi.encodePacked(
                tokenAmounts,
                details.tokens[i].token.universalBalanceOf(address(this))
            );
        }

        (bool success,) = address(curveInfo.curve).call(
            abi.encodePacked(
                _getCurveAddLiquiditySelector(curveInfo.tokenCount),
                tokenAmounts,
                uint256(0)
            )
        );

        require(success, 'add_liquidity failed');
    }
}
