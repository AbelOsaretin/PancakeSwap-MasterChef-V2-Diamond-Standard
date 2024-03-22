// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {LibAppStorage} from "../libraries/LibAppStorage.sol";
import {IMasterChef} from "../interfaces/IMasterChef.sol";
import {IBEP20} from "../interfaces/IBEP20.sol";
import {LibDiamond} from "../libraries/LibDiamond.sol";
import {SafeMath} from "../libraries/SafeMath.sol";
import {SafeBEP20} from "../libraries/SafeBEP20.sol";

// import {ReentrancyGuard} from "../ReentrancyGuard.sol";

contract MasterChefV2 {
    LibAppStorage.Layout internal l;

    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    event Init();
    event AddPool(
        uint256 indexed pid,
        uint256 allocPoint,
        IBEP20 indexed lpToken,
        bool isRegular
    );
    event SetPool(uint256 indexed pid, uint256 allocPoint);
    event UpdatePool(
        uint256 indexed pid,
        uint256 lastRewardBlock,
        uint256 lpSupply,
        uint256 accCakePerShare
    );
    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    event UpdateCakeRate(
        uint256 burnRate,
        uint256 regularFarmRate,
        uint256 specialFarmRate
    );
    event UpdateBurnAdmin(address indexed oldAdmin, address indexed newAdmin);
    event UpdateWhiteList(address indexed user, bool isValid);
    event UpdateBoostContract(address indexed boostContract);
    event UpdateBoostMultiplier(
        address indexed user,
        uint256 pid,
        uint256 oldMultiplier,
        uint256 newMultiplier
    );

    constructor(
        IMasterChef _MASTER_CHEF,
        IBEP20 _CAKE,
        uint256 _MASTER_PID,
        address _burnAdmin
    ) {
        l.MASTER_CHEF = _MASTER_CHEF;
        l.CAKE = _CAKE;
        l.MASTER_PID = _MASTER_PID;
        l.burnAdmin = _burnAdmin;
        l.MASTERCHEF_CAKE_PER_BLOCK = 40 * 1e18;
        l.ACC_CAKE_PRECISION = 1e18;
        l.BOOST_PRECISION = 100 * 1e10;
        l.MAX_BOOST_PRECISION = 200 * 1e10;
        l.CAKE_RATE_TOTAL_PRECISION = 1e12;
        l.cakeRateToBurn = 643750000000;
        l.cakeRateToRegularFarm = 62847222222;
        l.cakeRateToSpecialFarm = 293402777778;
    }

    modifier onlyBoostContract() {
        require(
            l.boostContract == msg.sender,
            "Ownable: caller is not the boost contract"
        );
        _;
    }

    modifier onlyOwner() {
        require(
            LibDiamond.contractOwner() == msg.sender,
            "Ownable: caller is not the owner"
        );
        _;
    }

    function init(IBEP20 dummyToken) external onlyOwner {
        uint256 balance = dummyToken.balanceOf(msg.sender);
        require(balance != 0, "MasterChefV2: Balance must exceed 0");
        dummyToken.transferFrom(msg.sender, address(this), balance);
        dummyToken.approve(address(l.MASTER_CHEF), balance);
        l.MASTER_CHEF.deposit(l.MASTER_PID, balance);
        // MCV2 start to earn CAKE reward from current block in MCV1 pool
        l.lastBurnedBlock = block.number;
        emit Init();
    }

    function poolLength() public view returns (uint256 pools) {
        pools = l.poolInfo.length;
    }

    // /////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    ///////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function add(
        uint256 _allocPoint,
        IBEP20 _lpToken,
        bool _isRegular,
        bool _withUpdate
    ) external onlyOwner {
        require(_lpToken.balanceOf(address(this)) >= 0, "None BEP20 tokens");
        // stake CAKE token will cause staked token and reward token mixed up,
        // may cause staked tokens withdraw as reward token,never do it.
        require(_lpToken != l.CAKE, "CAKE token can't be added to farm pools");

        if (_withUpdate) {
            massUpdatePools();
        }

        if (_isRegular) {
            l.totalRegularAllocPoint = l.totalRegularAllocPoint.add(
                _allocPoint
            );
        } else {
            l.totalSpecialAllocPoint = l.totalSpecialAllocPoint.add(
                _allocPoint
            );
        }
        l.lpToken.push(_lpToken);

        l.poolInfo.push(
            LibAppStorage.PoolInfo({
                allocPoint: _allocPoint,
                lastRewardBlock: block.number,
                accCakePerShare: 0,
                isRegular: _isRegular,
                totalBoostedShare: 0
            })
        );
        emit AddPool(
            l.lpToken.length.sub(1),
            _allocPoint,
            _lpToken,
            _isRegular
        );
    }

    function set(
        uint256 _pid,
        uint256 _allocPoint,
        bool _withUpdate
    ) external onlyOwner {
        // No matter _withUpdate is true or false, we need to execute updatePool once before set the pool parameters.
        updatePool(_pid);

        if (_withUpdate) {
            massUpdatePools();
        }

        if (l.poolInfo[_pid].isRegular) {
            l.totalRegularAllocPoint = l
                .totalRegularAllocPoint
                .sub(l.poolInfo[_pid].allocPoint)
                .add(_allocPoint);
        } else {
            l.totalSpecialAllocPoint = l
                .totalSpecialAllocPoint
                .sub(l.poolInfo[_pid].allocPoint)
                .add(_allocPoint);
        }
        l.poolInfo[_pid].allocPoint = _allocPoint;
        emit SetPool(_pid, _allocPoint);
    }

    /// @notice View function for checking pending CAKE rewards.
    /// @param _pid The id of the pool. See `poolInfo`.
    /// @param _user Address of the user.
    function pendingCake(
        uint256 _pid,
        address _user
    ) external view returns (uint256) {
        LibAppStorage.PoolInfo memory pool = l.poolInfo[_pid];
        LibAppStorage.UserInfo memory user = l.userInfo[_pid][_user];
        uint256 accCakePerShare = pool.accCakePerShare;
        uint256 lpSupply = pool.totalBoostedShare;

        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier = block.number.sub(pool.lastRewardBlock);

            uint256 cakeReward = multiplier
                .mul(cakePerBlock(pool.isRegular))
                .mul(pool.allocPoint)
                .div(
                    (
                        pool.isRegular
                            ? l.totalRegularAllocPoint
                            : l.totalSpecialAllocPoint
                    )
                );
            accCakePerShare = accCakePerShare.add(
                cakeReward.mul(l.ACC_CAKE_PRECISION).div(lpSupply)
            );
        }

        uint256 boostedAmount = user
            .amount
            .mul(getBoostMultiplier(_user, _pid))
            .div(l.BOOST_PRECISION);
        return
            boostedAmount.mul(accCakePerShare).div(l.ACC_CAKE_PRECISION).sub(
                user.rewardDebt
            );
    }

    /// @notice Update cake reward for all the active pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = l.poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            LibAppStorage.PoolInfo memory pool = l.poolInfo[pid];
            if (pool.allocPoint != 0) {
                updatePool(pid);
            }
        }
    }

    /// @notice Calculates and returns the `amount` of CAKE per block.
    /// @param _isRegular If the pool belongs to regular or special.
    function cakePerBlock(
        bool _isRegular
    ) public view returns (uint256 amount) {
        if (_isRegular) {
            amount = l
                .MASTERCHEF_CAKE_PER_BLOCK
                .mul(l.cakeRateToRegularFarm)
                .div(l.CAKE_RATE_TOTAL_PRECISION);
        } else {
            amount = l
                .MASTERCHEF_CAKE_PER_BLOCK
                .mul(l.cakeRateToSpecialFarm)
                .div(l.CAKE_RATE_TOTAL_PRECISION);
        }
    }

    /// @notice Calculates and returns the `amount` of CAKE per block to burn.
    function cakePerBlockToBurn() public view returns (uint256 amount) {
        amount = l.MASTERCHEF_CAKE_PER_BLOCK.mul(l.cakeRateToBurn).div(
            l.CAKE_RATE_TOTAL_PRECISION
        );
    }

    /// @notice Update reward variables for the given pool.
    /// @param _pid The id of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(
        uint256 _pid
    ) public returns (LibAppStorage.PoolInfo memory pool) {
        pool = l.poolInfo[_pid];
        if (block.number > pool.lastRewardBlock) {
            uint256 lpSupply = pool.totalBoostedShare;
            uint256 totalAllocPoint = (
                pool.isRegular
                    ? l.totalRegularAllocPoint
                    : l.totalSpecialAllocPoint
            );

            if (lpSupply > 0 && totalAllocPoint > 0) {
                uint256 multiplier = block.number.sub(pool.lastRewardBlock);
                uint256 cakeReward = multiplier
                    .mul(cakePerBlock(pool.isRegular))
                    .mul(pool.allocPoint)
                    .div(totalAllocPoint);
                pool.accCakePerShare = pool.accCakePerShare.add(
                    (cakeReward.mul(l.ACC_CAKE_PRECISION).div(lpSupply))
                );
            }
            pool.lastRewardBlock = block.number;
            l.poolInfo[_pid] = pool;
            emit UpdatePool(
                _pid,
                pool.lastRewardBlock,
                lpSupply,
                pool.accCakePerShare
            );
        }
    }

    /// @notice Deposit LP tokens to pool.
    /// @param _pid The id of the pool. See `poolInfo`.
    /// @param _amount Amount of LP tokens to deposit.
    function deposit(uint256 _pid, uint256 _amount) external {
        LibAppStorage.PoolInfo memory pool = updatePool(_pid);
        LibAppStorage.UserInfo storage user = l.userInfo[_pid][msg.sender];

        require(
            pool.isRegular || l.whiteList[msg.sender],
            "MasterChefV2: The address is not available to deposit in this pool"
        );

        uint256 multiplier = getBoostMultiplier(msg.sender, _pid);

        if (user.amount > 0) {
            settlePendingCake(msg.sender, _pid, multiplier);
        }

        if (_amount > 0) {
            uint256 before = l.lpToken[_pid].balanceOf(address(this));
            l.lpToken[_pid].safeTransferFrom(
                msg.sender,
                address(this),
                _amount
            );
            _amount = l.lpToken[_pid].balanceOf(address(this)).sub(before);
            user.amount = user.amount.add(_amount);

            // Update total boosted share.
            pool.totalBoostedShare = pool.totalBoostedShare.add(
                _amount.mul(multiplier).div(l.BOOST_PRECISION)
            );
        }

        user.rewardDebt = user
            .amount
            .mul(multiplier)
            .div(l.BOOST_PRECISION)
            .mul(pool.accCakePerShare)
            .div(l.ACC_CAKE_PRECISION);
        l.poolInfo[_pid] = pool;

        emit Deposit(msg.sender, _pid, _amount);
    }

    /// @notice Withdraw LP tokens from pool.
    /// @param _pid The id of the pool. See `poolInfo`.
    /// @param _amount Amount of LP tokens to withdraw.
    function withdraw(uint256 _pid, uint256 _amount) external {
        LibAppStorage.PoolInfo memory pool = updatePool(_pid);
        LibAppStorage.UserInfo storage user = l.userInfo[_pid][msg.sender];

        require(user.amount >= _amount, "withdraw: Insufficient");

        uint256 multiplier = getBoostMultiplier(msg.sender, _pid);

        settlePendingCake(msg.sender, _pid, multiplier);

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            l.lpToken[_pid].safeTransfer(msg.sender, _amount);
        }

        user.rewardDebt = user
            .amount
            .mul(multiplier)
            .div(l.BOOST_PRECISION)
            .mul(pool.accCakePerShare)
            .div(l.ACC_CAKE_PRECISION);
        l.poolInfo[_pid].totalBoostedShare = l
            .poolInfo[_pid]
            .totalBoostedShare
            .sub(_amount.mul(multiplier).div(l.BOOST_PRECISION));

        emit Withdraw(msg.sender, _pid, _amount);
    }

    /// @notice Harvests CAKE from `MASTER_CHEF` MCV1 and pool `MASTER_PID` to MCV2.
    function harvestFromMasterChef() public {
        l.MASTER_CHEF.deposit(l.MASTER_PID, 0);
    }

    /// @notice Withdraw without caring about the rewards. EMERGENCY ONLY.
    /// @param _pid The id of the pool. See `poolInfo`.
    function emergencyWithdraw(uint256 _pid) external {
        LibAppStorage.PoolInfo storage pool = l.poolInfo[_pid];
        LibAppStorage.UserInfo storage user = l.userInfo[_pid][msg.sender];

        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        uint256 boostedAmount = amount
            .mul(getBoostMultiplier(msg.sender, _pid))
            .div(l.BOOST_PRECISION);
        pool.totalBoostedShare = pool.totalBoostedShare > boostedAmount
            ? pool.totalBoostedShare.sub(boostedAmount)
            : 0;

        // Note: transfer can fail or succeed if `amount` is zero.
        l.lpToken[_pid].safeTransfer(msg.sender, amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    /// @notice Send CAKE pending for burn to `burnAdmin`.
    /// @param _withUpdate Whether call "massUpdatePools" operation.
    function burnCake(bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 multiplier = block.number.sub(l.lastBurnedBlock);
        uint256 pendingCakeToBurn = multiplier.mul(cakePerBlockToBurn());

        // SafeTransfer CAKE
        _safeTransfer(l.burnAdmin, pendingCakeToBurn);
        l.lastBurnedBlock = block.number;
    }

    /// @notice Update the % of CAKE distributions for burn, regular pools and special pools.
    /// @param _burnRate The % of CAKE to burn each block.
    /// @param _regularFarmRate The % of CAKE to regular pools each block.
    /// @param _specialFarmRate The % of CAKE to special pools each block.
    /// @param _withUpdate Whether call "massUpdatePools" operation.
    function updateCakeRate(
        uint256 _burnRate,
        uint256 _regularFarmRate,
        uint256 _specialFarmRate,
        bool _withUpdate
    ) external onlyOwner {
        require(
            _burnRate > 0 && _regularFarmRate > 0 && _specialFarmRate > 0,
            "MasterChefV2: Cake rate must be greater than 0"
        );
        require(
            _burnRate.add(_regularFarmRate).add(_specialFarmRate) ==
                l.CAKE_RATE_TOTAL_PRECISION,
            "MasterChefV2: Total rate must be 1e12"
        );
        if (_withUpdate) {
            massUpdatePools();
        }
        // burn cake base on old burn cake rate
        burnCake(false);

        l.cakeRateToBurn = _burnRate;
        l.cakeRateToRegularFarm = _regularFarmRate;
        l.cakeRateToSpecialFarm = _specialFarmRate;

        emit UpdateCakeRate(_burnRate, _regularFarmRate, _specialFarmRate);
    }

    /// @notice Update burn admin address.
    /// @param _newAdmin The new burn admin address.
    function updateBurnAdmin(address _newAdmin) external onlyOwner {
        require(
            _newAdmin != address(0),
            "MasterChefV2: Burn admin address must be valid"
        );
        require(
            _newAdmin != l.burnAdmin,
            "MasterChefV2: Burn admin address is the same with current address"
        );
        address _oldAdmin = l.burnAdmin;
        l.burnAdmin = _newAdmin;
        emit UpdateBurnAdmin(_oldAdmin, _newAdmin);
    }

    /// @notice Update whitelisted addresses for special pools.
    /// @param _user The address to be updated.
    /// @param _isValid The flag for valid or invalid.
    function updateWhiteList(address _user, bool _isValid) external onlyOwner {
        require(
            _user != address(0),
            "MasterChefV2: The white list address must be valid"
        );

        l.whiteList[_user] = _isValid;
        emit UpdateWhiteList(_user, _isValid);
    }

    /// @notice Update boost contract address and max boost factor.
    /// @param _newBoostContract The new address for handling all the share boosts.
    function updateBoostContract(address _newBoostContract) external onlyOwner {
        require(
            _newBoostContract != address(0) &&
                _newBoostContract != l.boostContract,
            "MasterChefV2: New boost contract address must be valid"
        );

        l.boostContract = _newBoostContract;
        emit UpdateBoostContract(_newBoostContract);
    }

    /// @notice Update user boost factor.
    /// @param _user The user address for boost factor updates.
    /// @param _pid The pool id for the boost factor updates.
    /// @param _newMultiplier New boost multiplier.
    function updateBoostMultiplier(
        address _user,
        uint256 _pid,
        uint256 _newMultiplier
    ) external onlyBoostContract {
        require(
            _user != address(0),
            "MasterChefV2: The user address must be valid"
        );
        require(
            l.poolInfo[_pid].isRegular,
            "MasterChefV2: Only regular farm could be boosted"
        );
        require(
            _newMultiplier >= l.BOOST_PRECISION &&
                _newMultiplier <= l.MAX_BOOST_PRECISION,
            "MasterChefV2: Invalid new boost multiplier"
        );

        LibAppStorage.PoolInfo memory pool = updatePool(_pid);
        LibAppStorage.UserInfo storage user = l.userInfo[_pid][_user];

        uint256 prevMultiplier = getBoostMultiplier(_user, _pid);
        settlePendingCake(_user, _pid, prevMultiplier);

        user.rewardDebt = user
            .amount
            .mul(_newMultiplier)
            .div(l.BOOST_PRECISION)
            .mul(pool.accCakePerShare)
            .div(l.ACC_CAKE_PRECISION);
        pool.totalBoostedShare = pool
            .totalBoostedShare
            .sub(user.amount.mul(prevMultiplier).div(l.BOOST_PRECISION))
            .add(user.amount.mul(_newMultiplier).div(l.BOOST_PRECISION));
        l.poolInfo[_pid] = pool;
        l.userInfo[_pid][_user].boostMultiplier = _newMultiplier;

        emit UpdateBoostMultiplier(_user, _pid, prevMultiplier, _newMultiplier);
    }

    /// @notice Get user boost multiplier for specific pool id.
    /// @param _user The user address.
    /// @param _pid The pool id.
    function getBoostMultiplier(
        address _user,
        uint256 _pid
    ) public view returns (uint256) {
        uint256 multiplier = l.userInfo[_pid][_user].boostMultiplier;
        return multiplier > l.BOOST_PRECISION ? multiplier : l.BOOST_PRECISION;
    }

    /// @notice Settles, distribute the pending CAKE rewards for given user.
    /// @param _user The user address for settling rewards.
    /// @param _pid The pool id.
    /// @param _boostMultiplier The user boost multiplier in specific pool id.
    function settlePendingCake(
        address _user,
        uint256 _pid,
        uint256 _boostMultiplier
    ) internal {
        LibAppStorage.UserInfo memory user = l.userInfo[_pid][_user];

        uint256 boostedAmount = user.amount.mul(_boostMultiplier).div(
            l.BOOST_PRECISION
        );
        uint256 accCake = boostedAmount
            .mul(l.poolInfo[_pid].accCakePerShare)
            .div(l.ACC_CAKE_PRECISION);
        uint256 pending = accCake.sub(user.rewardDebt);
        // SafeTransfer CAKE
        _safeTransfer(_user, pending);
    }

    /// @notice Safe Transfer CAKE.
    /// @param _to The CAKE receiver address.
    /// @param _amount transfer CAKE amounts.
    function _safeTransfer(address _to, uint256 _amount) internal {
        if (_amount > 0) {
            // Check whether MCV2 has enough CAKE. If not, harvest from MCV1.
            if (l.CAKE.balanceOf(address(this)) < _amount) {
                harvestFromMasterChef();
            }
            uint256 balance = l.CAKE.balanceOf(address(this));
            if (balance < _amount) {
                _amount = balance;
            }
            l.CAKE.safeTransfer(_to, _amount);
        }
    }
}
