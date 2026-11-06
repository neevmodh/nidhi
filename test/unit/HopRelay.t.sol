// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {CCIPLocalSimulator} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {BurnMintERC677Helper} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {IRouterClient} from "@chainlink/contracts-ccip/contracts/interfaces/IRouterClient.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

import {NidhiDispatcher} from "../../src/NidhiDispatcher.sol";
import {DestinationReceiver} from "../../src/DestinationReceiver.sol";
import {NidhiHopRelay} from "../../src/NidhiHopRelay.sol";
import {Mandate} from "../../src/libraries/Mandate.sol";
import {AckLib} from "../../src/libraries/AckLib.sol";

/// Multi-hop grant over Chainlink's local simulator:
///   dispatcher --CCIP--> relay --CCIP--> receiver --> grantee, and the ACK back through the relay to SETTLED.
/// The dispatcher and the receiver are the production contracts, unchanged; only the relay is new.
contract HopRelayTest is Test {
    CCIPLocalSimulator sim;
    IRouterClient router;
    BurnMintERC677Helper bnm;
    uint64 sel;

    NidhiDispatcher dispatcher;
    NidhiHopRelay relay;
    DestinationReceiver receiver;

    address dao = makeAddr("dao");
    address grantee = makeAddr("grantee");
    uint256 constant AMOUNT = 1e18;

    function setUp() public {
        sim = new CCIPLocalSimulator();
        (uint64 s, IRouterClient r,,,, BurnMintERC677Helper b,) = sim.configuration();
        (sel, router, bnm) = (s, r, b);

        dispatcher = new NidhiDispatcher(address(router), address(0), dao);
        relay = new NidhiHopRelay(address(router), dao);
        receiver = new DestinationReceiver(address(router), address(0), dao);

        vm.startPrank(dao);
        dispatcher.setHook(address(this)); // this test plays the hook
        dispatcher.addDestination(sel, address(relay)); // to the source, the relay is the destination
        relay.setOnward(sel, address(receiver));
        relay.addUpstream(sel, address(dispatcher));
        relay.allowToken(address(bnm));
        receiver.allowToken(address(bnm));
        receiver.addSource(sel, address(relay)); // to the final receiver, the relay is the source
        // The local simulator runs every hop nested in one transaction, so the first hop's gas budget must cover the
        // whole route. On real CCIP each hop executes separately with its own budget.
        dispatcher.setDestGasLimit(6_000_000);
        relay.setGasLimit(3_000_000);
        receiver.setAckGasLimit(1_500_000);
        vm.stopPrank();

        vm.deal(address(dispatcher), 1 ether);
        vm.deal(address(relay), 1 ether);
        vm.deal(address(receiver), 1 ether);
    }

    function _mandate(bytes32 id) internal view returns (Mandate memory m) {
        m.grantId = id;
        m.recipient = grantee;
        m.tokenOut = address(bnm);
        m.amountIn = 1;
        m.destChainSelector = sel;
        m.destReceiver = address(relay);
    }

    function _send(bytes32 id) internal returns (bytes32 messageId) {
        bnm.drip(address(dispatcher)); // 1e18 into the dispatcher, as the hook's take() would
        messageId = dispatcher.dispatch(_mandate(id), AMOUNT);
    }

    function test_twoHopGrantSettles() public {
        bytes32 id = keccak256("hop-1");
        bytes32 messageId = _send(id);

        assertEq(bnm.balanceOf(grantee), AMOUNT, "grantee paid on the final chain");
        assertEq(uint8(dispatcher.statusOf(id)), uint8(NidhiDispatcher.Status.SETTLED), "source ledger settled");
        NidhiHopRelay.Hop memory h = relay.getHop(id);
        assertEq(uint8(h.status), uint8(NidhiHopRelay.HopStatus.ACKED), "relay relayed the ACK");
        assertEq(h.inboundMessageId, messageId, "relay remembers the source's messageId");
        assertTrue(h.onwardMessageId != bytes32(0), "relay forwarded");
        assertEq(bnm.balanceOf(address(relay)), 0, "nothing rests in the relay");
        assertEq(bnm.balanceOf(address(dispatcher)), 0, "nothing rests in the dispatcher");
        assertEq(dispatcher.getGrant(id).messageId, messageId, "ledger keeps the source messageId");
    }

    function test_heldOnFinalChainShowsHeldThenSettles() public {
        vm.prank(dao);
        receiver.setPayoutsPaused(true);
        bytes32 id = keccak256("hop-held");
        _send(id);
        assertEq(
            uint8(dispatcher.statusOf(id)), uint8(NidhiDispatcher.Status.HELD), "HELD travels back through the relay"
        );
        assertEq(bnm.balanceOf(grantee), 0);

        vm.prank(dao);
        receiver.setPayoutsPaused(false);
        receiver.retryPayout(id);
        assertEq(bnm.balanceOf(grantee), AMOUNT, "paid on retry");
        assertEq(uint8(dispatcher.statusOf(id)), uint8(NidhiDispatcher.Status.SETTLED), "second ACK settles it");
    }

    function test_unknownSenderIsRejected() public {
        Client.EVMTokenAmount[] memory none = new Client.EVMTokenAmount[](0);
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: bytes32(uint256(1)),
            sourceChainSelector: sel,
            sender: abi.encode(makeAddr("stranger")),
            data: AckLib.encodeGrant(keccak256("x"), grantee, AMOUNT),
            destTokenAmounts: none
        });
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(NidhiHopRelay.UnknownSender.selector, sel, makeAddr("stranger")));
        relay.ccipReceive(m);
    }

    function test_forgedAckIsRejected() public {
        bytes32 id = keccak256("hop-forged");
        _send(id);
        Client.Any2EVMMessage memory m = Client.Any2EVMMessage({
            messageId: bytes32(uint256(2)),
            sourceChainSelector: sel,
            sender: abi.encode(address(receiver)),
            data: AckLib.encodeAck(id, bytes32(uint256(999)), AMOUNT, AckLib.PAID), // wrong onward messageId
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
        vm.prank(address(router));
        vm.expectRevert(abi.encodeWithSelector(NidhiHopRelay.BadAck.selector, id));
        relay.ccipReceive(m);
    }

    function test_wiringIsSetOnceAndAddOnly() public {
        vm.startPrank(dao);
        vm.expectRevert(NidhiHopRelay.AlreadySet.selector);
        relay.setOnward(sel, makeAddr("other"));
        vm.expectRevert(NidhiHopRelay.AlreadySet.selector);
        relay.addUpstream(sel, makeAddr("other"));
        vm.stopPrank();
        vm.expectRevert();
        relay.allowToken(makeAddr("t")); // not the owner
    }

    function test_retryOnlyWhenPending() public {
        bytes32 id = keccak256("hop-2");
        _send(id);
        vm.expectRevert(abi.encodeWithSelector(NidhiHopRelay.NotPending.selector, id));
        relay.retryForward(id);
        vm.expectRevert(abi.encodeWithSelector(NidhiHopRelay.NotPending.selector, id));
        relay.retryAck(id);
    }

    function test_selfOnlyEntryPoints() public {
        vm.expectRevert(NidhiHopRelay.OnlySelf.selector);
        relay.sendOnward(bytes32(0));
        vm.expectRevert(NidhiHopRelay.OnlySelf.selector);
        relay.sendAckUpstream(bytes32(0));
    }
}
