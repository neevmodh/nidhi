// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CCIPLocalRouter} from "@chainlink/local/src/ccip/CCIPLocalRouter.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {NidhiBase} from "../utils/NidhiBase.sol";
import {NidhiSwapRouter} from "../../src/NidhiSwapRouter.sol";
import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {Mandate} from "../../src/libraries/Mandate.sol";
import {AckLib} from "../../src/libraries/AckLib.sol";

contract EdgeCasesTest is NidhiBase {
    uint128 constant AMOUNT_IN = 0.001 ether;

    // =================================================================== native-gas CCIP fees (live ACK lane uses this)

    function test_nativeFeesOnBothLanes() public {
        CCIPLocalRouter(address(ccipRouter)).setFee(0.01 ether);
        NidhiDispatcher d = new NidhiDispatcher(address(ccipRouter), address(0), chainSelector, daoOwner);
        DestinationReceiver r =
            new DestinationReceiver(address(ccipRouter), chainSelector, address(bnm), address(0), daoOwner);
        vm.startPrank(daoOwner);
        d.setHook(address(this)); // this test plays the hook
        d.setDestReceiver(address(r));
        r.setSourceDispatcher(address(d));
        vm.stopPrank();
        vm.deal(address(d), 1 ether);
        vm.deal(address(r), 1 ether);

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        m.destReceiver = address(r);
        bnm.drip(address(d)); // tokens "taken" into the dispatcher by the hook
        d.dispatch(m, 1 ether);

        assertEq(bnm.balanceOf(recipient), 1 ether);
        assertEq(uint8(d.statusOf(m.grantId)), uint8(NidhiDispatcher.Status.SETTLED));
        assertEq(address(d).balance, 0.99 ether, "source fee paid in native");
        assertEq(address(r).balance, 0.99 ether, "ACK fee paid in native");

        // fee withdrawal (native)
        vm.prank(daoOwner);
        d.withdrawFees(daoOwner, 0.5 ether);
        assertEq(daoOwner.balance, 0.5 ether);
        vm.prank(daoOwner);
        r.withdrawFees(daoOwner, 0.5 ether);
        assertEq(daoOwner.balance, 1 ether);
    }

    function test_revert_insufficientNativeFee() public {
        CCIPLocalRouter(address(ccipRouter)).setFee(0.01 ether);
        NidhiDispatcher d = new NidhiDispatcher(address(ccipRouter), address(0), chainSelector, daoOwner);
        vm.startPrank(daoOwner);
        d.setHook(address(this));
        d.setDestReceiver(address(receiver));
        vm.stopPrank();
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bnm.drip(address(d));
        vm.expectRevert(abi.encodeWithSelector(NidhiDispatcher.InsufficientFee.selector, 0, 0.01 ether));
        d.dispatch(m, 1 ether);
    }

    // =================================================================== dispatcher guards

    function test_revert_dispatcherGuards() public {
        NidhiDispatcher d = new NidhiDispatcher(address(ccipRouter), link, chainSelector, daoOwner);
        vm.prank(daoOwner);
        vm.expectRevert(NidhiDispatcher.ZeroAddress.selector);
        d.setHook(address(0));
        vm.prank(daoOwner);
        d.setHook(address(this));

        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        vm.expectRevert(NidhiDispatcher.NotConfigured.selector);
        d.dispatch(m, 1);

        vm.startPrank(daoOwner);
        vm.expectRevert(NidhiDispatcher.ZeroAddress.selector);
        d.setDestReceiver(address(0));
        d.setDestReceiver(address(receiver));
        d.setDestGasLimit(700_000);
        vm.stopPrank();
        assertEq(d.destGasLimit(), 700_000);

        vm.expectRevert(abi.encodeWithSelector(NidhiDispatcher.InsufficientTokens.selector, 0, 1 ether));
        d.dispatch(m, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        d.setDestGasLimit(1);
        vm.prank(daoOwner);
        vm.expectRevert(NidhiDispatcher.ZeroAddress.selector);
        d.withdrawFees(address(0), 1);
    }

    function test_revert_duplicateDispatch() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _swap(m, hd); // settles via the real hook
        vm.prank(address(hook));
        vm.expectRevert(abi.encodeWithSelector(NidhiDispatcher.GrantExists.selector, m.grantId));
        dispatcher.dispatch(m, 1);
    }

    function test_withdrawLinkFees() public {
        uint256 bal = _bal(link, address(dispatcher));
        vm.prank(daoOwner);
        dispatcher.withdrawFees(daoOwner, bal);
        assertEq(_bal(link, daoOwner), bal);
    }

    // =================================================================== forged / malformed ACKs

    function _ack(bytes memory data, Client.EVMTokenAmount[] memory t) internal {
        Client.Any2EVMMessage memory msg_ = Client.Any2EVMMessage({
            messageId: bytes32(uint256(99)),
            sourceChainSelector: chainSelector,
            sender: abi.encode(address(receiver)),
            data: data,
            destTokenAmounts: t
        });
        vm.prank(address(ccipRouter));
        dispatcher.ccipReceive(msg_);
    }

    function _settledGrant() internal returns (bytes32 id, NidhiDispatcher.Grant memory g) {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        _swap(m, hd);
        id = m.grantId;
        g = dispatcher.getGrant(id);
    }

    function test_revert_ackWithTokens() public {
        Client.EVMTokenAmount[] memory t = new Client.EVMTokenAmount[](1);
        t[0] = Client.EVMTokenAmount(address(bnm), 1);
        vm.expectRevert(abi.encodeWithSelector(NidhiDispatcher.InvalidAck.selector, bytes32(0)));
        _ack(AckLib.encodeAck(bytes32(0), bytes32(0), 0, AckLib.PAID), t);
    }

    function test_revert_ackWrongAmount() public {
        (bytes32 id, NidhiDispatcher.Grant memory g) = _settledGrant();
        vm.expectRevert(abi.encodeWithSelector(NidhiDispatcher.InvalidAck.selector, id));
        _ack(AckLib.encodeAck(id, g.messageId, g.amount + 1, AckLib.PAID), new Client.EVMTokenAmount[](0));
    }

    function test_revert_ackWrongMessageId() public {
        (bytes32 id, NidhiDispatcher.Grant memory g) = _settledGrant();
        vm.expectRevert(
            abi.encodeWithSelector(NidhiDispatcher.MessageIdMismatch.selector, g.messageId, bytes32(uint256(1)))
        );
        _ack(AckLib.encodeAck(id, bytes32(uint256(1)), g.amount, AckLib.PAID), new Client.EVMTokenAmount[](0));
    }

    function test_revert_ackCannotRegressSettled() public {
        (bytes32 id, NidhiDispatcher.Grant memory g) = _settledGrant();
        vm.expectRevert(abi.encodeWithSelector(NidhiDispatcher.InvalidAck.selector, id));
        _ack(AckLib.encodeAck(id, g.messageId, g.amount, AckLib.HELD), new Client.EVMTokenAmount[](0));
    }

    function test_revert_ackForUnknownGrant() public {
        bytes32 id = keccak256("never dispatched");
        vm.expectRevert(abi.encodeWithSelector(NidhiDispatcher.InvalidAck.selector, id));
        _ack(AckLib.encodeAck(id, bytes32(uint256(5)), 0, AckLib.PAID), new Client.EVMTokenAmount[](0));
    }

    // =================================================================== receiver guards

    function _grantMsg(bytes32 id, address to, uint256 declared, address token, uint256 sent)
        internal
        view
        returns (Client.Any2EVMMessage memory)
    {
        Client.EVMTokenAmount[] memory t = new Client.EVMTokenAmount[](1);
        t[0] = Client.EVMTokenAmount(token, sent);
        return Client.Any2EVMMessage({
            messageId: keccak256(abi.encode(id)),
            sourceChainSelector: chainSelector,
            sender: abi.encode(address(dispatcher)),
            data: AckLib.encodeGrant(id, to, declared),
            destTokenAmounts: t
        });
    }

    function test_revert_receiverRejectsWrongTokenOrAmount() public {
        vm.startPrank(address(ccipRouter));
        vm.expectRevert(DestinationReceiver.UnexpectedTokens.selector);
        receiver.ccipReceive(_grantMsg(bytes32(uint256(1)), recipient, 1, address(weth), 1));
        vm.expectRevert(abi.encodeWithSelector(DestinationReceiver.AmountMismatch.selector, 2, 1));
        receiver.ccipReceive(_grantMsg(bytes32(uint256(1)), recipient, 2, address(bnm), 1));
        vm.stopPrank();
    }

    function test_revert_receiverRejectsDuplicateGrant() public {
        (bytes32 id,) = _settledGrant();
        vm.prank(address(ccipRouter));
        vm.expectRevert(abi.encodeWithSelector(DestinationReceiver.DuplicateGrant.selector, id));
        receiver.ccipReceive(_grantMsg(id, recipient, 1, address(bnm), 1));
    }

    function test_revert_receiverInternalsAreSelfOnly() public {
        vm.expectRevert(DestinationReceiver.OnlySelf.selector);
        receiver.executePayout(address(this), 1);
        vm.expectRevert(DestinationReceiver.OnlySelf.selector);
        receiver.sendAck(bytes32(0));
    }

    function test_revert_receiverAdminGuards() public {
        vm.expectRevert(abi.encodeWithSelector(DestinationReceiver.NoAckPending.selector, bytes32(0)));
        receiver.retryAck(bytes32(0));
        vm.startPrank(daoOwner);
        vm.expectRevert(DestinationReceiver.ZeroAddress.selector);
        receiver.recover(bytes32(0), address(0));
        vm.expectRevert(DestinationReceiver.ZeroAddress.selector);
        receiver.withdrawFees(address(0), 1);
        receiver.setAckGasLimit(250_000);
        vm.stopPrank();
        assertEq(receiver.ackGasLimit(), 250_000);

        // fee token can never be the bridged grant token
        DestinationReceiver r2 =
            new DestinationReceiver(address(ccipRouter), chainSelector, address(bnm), address(bnm), daoOwner);
        vm.prank(daoOwner);
        vm.expectRevert(DestinationReceiver.UnexpectedTokens.selector);
        r2.withdrawFees(daoOwner, 1);

        vm.expectRevert(DestinationReceiver.ZeroAddress.selector);
        new DestinationReceiver(address(ccipRouter), chainSelector, address(0), address(0), daoOwner);
        vm.prank(daoOwner);
        vm.expectRevert(DestinationReceiver.ZeroAddress.selector);
        r2.setSourceDispatcher(address(0));
    }

    // =================================================================== router guards

    function test_revert_routerGuards() public {
        Mandate memory m = _mandate(_newGrantId(), AMOUNT_IN);
        bytes memory hd = _hookData(m);
        vm.prank(executor);
        vm.expectRevert(NidhiSwapRouter.DeadlinePassed.selector);
        nidhiRouter.swap(key, _params(AMOUNT_IN), hd, block.timestamp - 1);

        PoolKey memory nativeKey = PoolKey(Currency.wrap(address(0)), key.currency1, 3000, 60, IHooks(address(hook)));
        vm.expectRevert(NidhiSwapRouter.NativeNotSupported.selector);
        nidhiRouter.swap(nativeKey, _params(AMOUNT_IN), hd, block.timestamp);

        vm.expectRevert(NidhiSwapRouter.NotPoolManager.selector);
        nidhiRouter.unlockCallback("");

        assertEq(nidhiRouter.msgSender(), address(0), "no initiator outside a swap");
    }

    function _bal(address token, address who) internal view returns (uint256) {
        (bool ok, bytes memory r) = token.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        require(ok);
        return abi.decode(r, (uint256));
    }
}
