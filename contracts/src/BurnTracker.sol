// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "./interfaces/IIntake.sol";
import {ResultJson} from "./libraries/ResultJson.sol";
import {IERC20} from "../vendor/openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../vendor/openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice A single project's permanent payer. Anyone may fund its next fixed refresh.
/// @dev The owner controls the template, protocol settings and manual recovery. Payments are final.
contract BurnTracker {
    using SafeERC20 for IERC20;

    uint8 public constant UNOPENED = 1;
    uint8 public constant IDLE = 2;
    uint8 public constant PENDING = 3;
    uint8 public constant STUCK = 4;
    uint8 public constant OPEN = 1;
    uint8 public constant CONTINUE = 2;
    uint8 public constant RECOVER = 3;

    error NotOwner();
    error NotPendingOwner();
    error InvalidAddress();
    error InvalidActions();
    error InvalidTiming();
    error InvalidBody();
    error InvalidHash();
    error InvalidState();
    error CooldownNotPassed(uint256 nextAt);
    error InvalidProof();
    error InvalidParentJobId();
    error NotSold();
    error PriceTooHigh(uint256 price, uint256 maxPrice);
    error UnexpectedCallback();
    error InvalidFailureStatus();
    error ReentrantCall();
    error IncorrectTokenAmount();

    event Ordered(bytes32 indexed requestId, uint8 kind, address indexed payer, uint256 amount, string parentJobId);
    event Updated(bytes32 indexed requestId, bytes32 resultHash, string uri);
    event Failed(bytes32 indexed requestId, uint8 status, bytes32 reason, uint8 newState);
    event BodySet(bytes prefix, bytes suffix);
    event ActionsSet(bytes32 openAction, bytes32 continueAction);
    event IntakeSet(address intake, address asset);
    event TimingSet(uint32 cooldown, uint32 staleAfter);
    event ResultHashSet(bytes32 indexed abandonedRequestId, bytes32 resultHash);
    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Withdrawn(address indexed token, address indexed to, uint256 amount);

    address public owner;
    address public pendingOwner;
    address public intake;
    address public asset;
    bytes32 public openAction;
    bytes32 public continueAction;
    bytes public bodyPrefix;
    bytes public bodySuffix;

    // A reserved, nonzero initial value keeps the FIRST callback from creating a storage slot.
    // It is not a proof: UNOPENED prevents updates until an authenticated completion/adoption.
    bytes32 public resultHash = bytes32(uint256(1));
    bytes32 public lastRequestId;

    // These fields occupy ONE slot. Its state/timing fields keep it nonzero for its entire life.
    struct Status {
        uint8 state;
        uint8 pendingKind;
        uint40 lastDone;
        uint40 orderedAt;
        uint40 staleAt;
        uint32 cooldown;
        uint32 staleAfter;
        // Share the already-touched status slot instead of charging a second SSTORE
        // for the reentrancy guard on every payment. 1 = available, 2 = entered.
        uint8 lock;
    }

    Status private _status;
    address private _pendingIntake;

    constructor(
        address owner_,
        address intake_,
        address asset_,
        bytes32 openAction_,
        bytes32 continueAction_,
        bytes memory bodyPrefix_,
        bytes memory bodySuffix_,
        uint32 cooldown_,
        uint32 staleAfter_
    ) {
        if (owner_ == address(0) || intake_ == address(0) || asset_ == address(0)) {
            revert InvalidAddress();
        }
        _checkActions(openAction_, continueAction_);
        _checkBody(bodyPrefix_, bodySuffix_);
        _checkTiming(cooldown_, staleAfter_);
        owner = owner_;
        intake = intake_;
        asset = asset_;
        openAction = openAction_;
        continueAction = continueAction_;
        bodyPrefix = bodyPrefix_;
        bodySuffix = bodySuffix_;
        _status = Status(UNOPENED, 0, 0, 0, 0, cooldown_, staleAfter_, 1);
        _pendingIntake = intake_;
        emit OwnershipTransferred(address(0), owner_);
        emit IntakeSet(intake_, asset_);
        emit ActionsSet(openAction_, continueAction_);
        emit BodySet(bodyPrefix_, bodySuffix_);
        emit TimingSet(cooldown_, staleAfter_);
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_status.lock != 1) revert ReentrantCall();
        _status.lock = 2;
        _;
        _status.lock = 1;
    }

    /// @notice Open the hosted project; retry after refusal, failure, or a lost/stale order.
    function open(bytes calldata body) external onlyOwner nonReentrant returns (bytes32 requestId) {
        uint8 state = _status.state;
        if (state != UNOPENED && state != STUCK && !_isStale()) revert InvalidState();
        if (body.length == 0 || body.length > 16_384) revert InvalidBody();
        return _order(OPEN, openAction, body, "", type(uint256).max);
    }

    /// @notice Fund the next version using the exact last completion document as proof.
    function updateBurntracker(bytes calldata resultJson, uint256 maxPrice)
        external
        nonReentrant
        returns (bytes32 requestId)
    {
        if (_status.state != IDLE) revert InvalidState();
        uint256 nextAt = nextUpdateAt();
        if (block.timestamp < nextAt) revert CooldownNotPassed(nextAt);
        if (keccak256(resultJson) != resultHash) revert InvalidProof();
        bytes memory parent = ResultJson.authenticatedParentId(resultJson);
        return _order(CONTINUE, continueAction, bytes.concat(bodyPrefix, parent, bodySuffix), string(parent), maxPrice);
    }

    /// @notice Owner override after a lost/blocked job or while idle. The owner verifies the parent off chain.
    function recover(string calldata parentJobId) external onlyOwner nonReentrant returns (bytes32 requestId) {
        _checkRecoverable();
        bytes memory parent = bytes(parentJobId);
        if (!ResultJson.isUuid(parent)) revert InvalidParentJobId();
        return
            _order(
                RECOVER, continueAction, bytes.concat(bodyPrefix, parent, bodySuffix), parentJobId, type(uint256).max
            );
    }

    /// @notice Adopt a verified off-chain completion and abandon any stale awaited callback.
    function setResultHash(bytes32 hash) external onlyOwner nonReentrant {
        _checkRecoverable();
        if (hash == bytes32(0)) revert InvalidHash();
        resultHash = hash;
        _finish(IDLE, true);
        emit ResultHashSet(lastRequestId, hash);
    }

    /// @dev Only two preinitialized slots are written; the URI is emitted, never stored.
    function onResult(bytes32 requestId, bytes32 hash, string calldata uri) external {
        _checkCallback(requestId);
        if (hash == bytes32(0)) revert InvalidHash();
        resultHash = hash;
        _finish(IDLE, true);
        emit Updated(requestId, hash, uri);
    }

    /// @dev Refusals distinguish the three order kinds; failures always need owner intervention.
    function onFailure(bytes32 requestId, uint8 failureStatus, bytes32 reason, uint16, uint16, bytes calldata)
        external
    {
        _checkCallback(requestId);
        if (failureStatus != 1 && failureStatus != 2) revert InvalidFailureStatus();
        uint8 newState = STUCK;
        if (failureStatus == 1) {
            if (_status.pendingKind == OPEN) newState = UNOPENED;
            else if (_status.pendingKind == CONTINUE) newState = IDLE;
        }
        _finish(newState, newState == IDLE);
        emit Failed(requestId, failureStatus, reason, newState);
    }

    function parentJobIdOf(bytes calldata resultJson) public pure returns (bytes memory) {
        return ResultJson.parentId(resultJson);
    }

    /// @notice Current continuation price in the asset's smallest units. Zero means not sold.
    function price() external view returns (uint256) {
        return IIntake(intake).priceOf(continueAction, asset);
    }

    /// @notice Cooldown deadline. An update also requires IDLE and the current proof.
    function nextUpdateAt() public view returns (uint256) {
        return uint256(_status.lastDone) + _status.cooldown;
    }

    function status()
        external
        view
        returns (
            uint8 state,
            uint8 pendingKind,
            uint40 lastDone,
            uint40 orderedAt,
            uint40 staleAt,
            uint32 cooldown,
            uint32 staleAfter
        )
    {
        Status memory s = _status;
        return (s.state, s.pendingKind, s.lastDone, s.orderedAt, s.staleAt, s.cooldown, s.staleAfter);
    }

    function setBody(bytes calldata prefix, bytes calldata suffix) external onlyOwner nonReentrant {
        _checkBody(prefix, suffix);
        bodyPrefix = prefix;
        bodySuffix = suffix;
        emit BodySet(prefix, suffix);
    }

    function setActions(bytes32 openAction_, bytes32 continueAction_) external onlyOwner nonReentrant {
        _checkActions(openAction_, continueAction_);
        openAction = openAction_;
        continueAction = continueAction_;
        emit ActionsSet(openAction_, continueAction_);
    }

    /// @notice Changes future orders. A pending order still authenticates its original Intake.
    function setIntake(address intake_, address asset_) external onlyOwner nonReentrant {
        if (intake_ == address(0) || asset_ == address(0)) revert InvalidAddress();
        intake = intake_;
        asset = asset_;
        emit IntakeSet(intake_, asset_);
    }

    /// @notice Cooldown applies immediately; an outstanding order's staleAt remains fixed.
    function setTiming(uint32 cooldown_, uint32 staleAfter_) external onlyOwner nonReentrant {
        _checkTiming(cooldown_, staleAfter_);
        _status.cooldown = cooldown_;
        _status.staleAfter = staleAfter_;
        emit TimingSet(cooldown_, staleAfter_);
    }

    function withdraw(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert InvalidAddress();
        IERC20(token).safeTransfer(to, amount);
        emit Withdrawn(token, to, amount);
    }

    function transferOwnership(address newOwner) external onlyOwner nonReentrant {
        if (newOwner == address(0)) revert InvalidAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external nonReentrant {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address previousOwner = owner;
        owner = msg.sender;
        delete pendingOwner;
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    function _order(uint8 kind, bytes32 action, bytes memory body, string memory parent, uint256 maxPrice)
        private
        returns (bytes32 requestId)
    {
        IIntake to = IIntake(intake);
        IERC20 token = IERC20(asset);
        uint256 amount = to.priceOf(action, address(token));
        if (amount == 0) revert NotSold();
        if (amount > maxPrice) revert PriceTooHigh(amount, maxPrice);

        _status.state = PENDING;
        _status.pendingKind = kind;
        _status.orderedAt = uint40(block.timestamp);
        _status.staleAt = uint40(block.timestamp + _status.staleAfter);
        _pendingIntake = address(to);

        uint256 balance = _balanceOf(token);
        _pullFromCaller(token, amount);
        if (_balanceOf(token) != balance + amount) revert IncorrectTokenAmount();
        // The ordinary exact approval uses a fixed ABI buffer; retain SafeERC20's
        // zero-first fallback for tokens that require clearing an old allowance.
        if (!_tryApprove(token, address(to), amount)) token.forceApprove(address(to), amount);
        requestId = to.requestWithFailure(
            action,
            body,
            IIntake.Callback(address(this), this.onResult.selector),
            this.onFailure.selector,
            address(token),
            amount
        );
        // The real Intake consumes its whole allowance. Also clean up a misconfigured replacement.
        if (token.allowance(address(this), address(to)) != 0) token.forceApprove(address(to), 0);
        if (_balanceOf(token) != balance) revert IncorrectTokenAmount();
        lastRequestId = requestId;
        emit Ordered(requestId, kind, msg.sender, amount, parent);
    }

    /// @dev Fixed-size balanceOf call avoids repeated dynamic ABI allocation on the payment path.
    /// Reverts and short return values are handled exactly as for the typed ERC-20 call.
    function _balanceOf(IERC20 token) private view returns (uint256 amount) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x70a0823100000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 4), address())
            if iszero(staticcall(gas(), token, ptr, 36, ptr, 32)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            if lt(returndatasize(), 32) { revert(0, 0) }
            amount := mload(ptr)
        }
    }

    function _tryApprove(IERC20 token, address spender, uint256 amount) private returns (bool ok) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x095ea7b300000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 4), spender)
            mstore(add(ptr, 36), amount)
            ok := call(gas(), token, 0, ptr, 68, ptr, 32)
            switch returndatasize()
            case 0 { ok := and(ok, gt(extcodesize(token), 0)) }
            default { ok := and(ok, and(iszero(lt(returndatasize(), 32)), eq(mload(ptr), 1))) }
        }
    }

    /// @dev SafeERC20 optional-return semantics with a fixed transferFrom buffer.
    /// The source is always this entry point's caller, never an owner-supplied address.
    function _pullFromCaller(IERC20 token, uint256 amount) private {
        bool ok;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x23b872dd00000000000000000000000000000000000000000000000000000000)
            mstore(add(ptr, 4), caller())
            mstore(add(ptr, 36), address())
            mstore(add(ptr, 68), amount)
            if iszero(call(gas(), token, 0, ptr, 100, ptr, 32)) {
                returndatacopy(ptr, 0, returndatasize())
                revert(ptr, returndatasize())
            }
            switch returndatasize()
            case 0 { ok := gt(extcodesize(token), 0) }
            default { ok := and(iszero(lt(returndatasize(), 32)), eq(mload(ptr), 1)) }
        }
        if (!ok) revert SafeERC20.SafeERC20FailedOperation(address(token));
    }

    function _checkCallback(bytes32 requestId) private view {
        if (_status.lock != 1 || msg.sender != _pendingIntake || _status.state != PENDING || requestId != lastRequestId)
        {
            revert UnexpectedCallback();
        }
    }

    function _finish(uint8 newState, bool restartCooldown) private {
        _status.state = newState;
        _status.pendingKind = 0;
        if (restartCooldown) _status.lastDone = uint40(block.timestamp);
    }

    function _isStale() private view returns (bool) {
        return _status.state == PENDING && block.timestamp >= _status.staleAt;
    }

    function _checkRecoverable() private view {
        if (_status.state != IDLE && _status.state != STUCK && !_isStale()) revert InvalidState();
    }

    function _checkTiming(uint32 cooldown_, uint32 staleAfter_) private pure {
        if (cooldown_ < 1 hours || cooldown_ > 30 days || staleAfter_ < 1 hours || staleAfter_ > 30 days) {
            revert InvalidTiming();
        }
    }

    function _checkActions(bytes32 openAction_, bytes32 continueAction_) private pure {
        if (openAction_ == bytes32(0) || continueAction_ == bytes32(0)) revert InvalidActions();
    }

    function _checkBody(bytes memory prefix, bytes memory suffix) private pure {
        if (prefix.length == 0 || suffix.length == 0 || prefix.length + suffix.length + 36 > 16_384) {
            revert InvalidBody();
        }
    }
}
