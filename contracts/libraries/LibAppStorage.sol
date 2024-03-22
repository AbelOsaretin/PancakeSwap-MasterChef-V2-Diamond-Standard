// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {IMasterChef} from "../interfaces/IMasterChef.sol";
import {IBEP20} from "../interfaces/IBEP20.sol";

library LibAppStorage {
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
        uint256 boostMultiplier;
    }

    struct PoolInfo {
        uint256 accCakePerShare;
        uint256 lastRewardBlock;
        uint256 allocPoint;
        uint256 totalBoostedShare;
        bool isRegular;
    }

    struct Layout {
        IMasterChef MASTER_CHEF;
        IBEP20 CAKE;
        address burnAdmin;
        address boostContract;
        PoolInfo[] poolInfo;
        IBEP20[] lpToken;
        mapping(uint256 => mapping(address => UserInfo)) userInfo;
        mapping(address => bool) whiteList;
        uint256 MASTER_PID;
        uint256 totalRegularAllocPoint;
        uint256 totalSpecialAllocPoint;
        uint256 MASTERCHEF_CAKE_PER_BLOCK;
        uint256 ACC_CAKE_PRECISION;
        uint256 BOOST_PRECISION;
        uint256 MAX_BOOST_PRECISION;
        uint256 CAKE_RATE_TOTAL_PRECISION;
        uint256 cakeRateToBurn;
        uint256 cakeRateToRegularFarm;
        uint256 cakeRateToSpecialFarm;
        uint256 lastBurnedBlock;
    }

    function layoutStorage() internal pure returns (Layout storage l) {
        assembly {
            l.slot := 0
        }
    }
}
