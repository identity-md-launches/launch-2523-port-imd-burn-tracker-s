// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IIntake} from "../../src/interfaces/IIntake.sol";

contract MockToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;
    bool public returnFalse;
    bool public noReturn;
    bool public zeroFirst;
    uint256 public fee;
    address public hookTarget;
    bytes public hookData;
    bool public reentered;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function configure(bool false_, bool noReturn_, bool zeroFirst_, uint256 fee_) external {
        returnFalse = false_;
        noReturn = noReturn_;
        zeroFirst = zeroFirst_;
        fee = fee_;
    }

    function setHook(address target, bytes calldata data) external {
        hookTarget = target;
        hookData = data;
    }

    function setAllowance(address holder, address spender, uint256 amount) external {
        allowance[holder][spender] = amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        if (zeroFirst && amount != 0 && allowance[msg.sender][spender] != 0) return false;
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        _transfer(msg.sender, to, amount);
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (returnFalse) return false;
        allowance[from][msg.sender] -= amount;
        _transfer(from, to, amount);
        if (hookTarget != address(0)) (reentered,) = hookTarget.call(hookData);
        if (noReturn) {
            assembly ("memory-safe") { return(0, 0) }
        }
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount - fee;
        totalSupply -= fee;
        emit Transfer(from, to, amount - fee);
    }
}

/// @dev Matches the protocol's payment, request storage, event, and one-shot callback behavior.
contract MockIntake is IIntake {
    struct Request {
        address payer;
        address callbackTarget;
        bytes4 callbackSelector;
        bool completed;
    }
    mapping(bytes32 => Request) public requests;
    mapping(bytes32 => bytes4) public failureSelectorOf;
    mapping(bytes32 => mapping(address => uint256)) public priceOf;
    uint256 public nonce;
    address public immutable writer;
    address public immutable payTo;
    bool public rejectOrder;
    bool public synchronousCallback;
    bool public synchronousDelivered;

    event Requested(
        bytes32 indexed requestId,
        address indexed payer,
        bytes32 indexed action,
        bytes body,
        address callbackTarget,
        bytes4 callbackSelector,
        address asset,
        uint256 amount
    );
    event Completed(bytes32 indexed requestId, uint8 status, bytes32 resultHash, string uri, bool delivered);

    constructor(address writer_, address treasury_) {
        writer = writer_;
        payTo = treasury_;
    }

    function setPrice(bytes32 action, address asset, uint256 amount) external {
        priceOf[action][asset] = amount;
    }

    function setReject(bool reject) external {
        rejectOrder = reject;
    }

    function setSynchronous(bool enable) external {
        synchronousCallback = enable;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 failure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(!rejectOrder, "intake rejected");
        require(priceOf[action][asset] != 0 && amount >= priceOf[action][asset], "not sold/underpaid");
        require(body.length != 0 && body.length <= 16_384, "bad body");
        require(MockToken(asset).allowance(msg.sender, address(this)) == amount, "approval not exact");
        (bool paid, bytes memory ret) = asset.call(abi.encodeCall(MockToken.transferFrom, (msg.sender, payTo, amount)));
        require(paid && (ret.length == 0 || abi.decode(ret, (bool))), "not paid");
        id = keccak256(abi.encode(address(this), block.chainid, ++nonce, msg.sender));
        requests[id] = Request(msg.sender, callback.target, callback.selector, false);
        failureSelectorOf[id] = failure;
        emit Requested(id, msg.sender, action, body, callback.target, callback.selector, asset, amount);
        if (synchronousCallback) {
            (synchronousDelivered,) =
                callback.target.call(abi.encodeWithSelector(callback.selector, id, bytes32(uint256(3)), "uri"));
        }
    }

    function complete(bytes32 id, uint8 status, bytes32 hash, string calldata uri, bytes32 reason)
        external
        returns (bool delivered)
    {
        require(msg.sender == writer, "not writer");
        Request storage r = requests[id];
        require(r.payer != address(0) && !r.completed, "not pending");
        r.completed = true;
        bytes memory data = status == 0
            ? abi.encodeWithSelector(r.callbackSelector, id, hash, uri)
            : abi.encodeWithSelector(failureSelectorOf[id], id, status, reason, uint16(0), uint16(0), bytes(""));
        (delivered,) = r.callbackTarget.call{gas: 200_000}(data);
        emit Completed(id, status, hash, uri, delivered);
    }
}
