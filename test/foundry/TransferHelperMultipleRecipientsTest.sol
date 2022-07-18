// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import { BaseConsiderationTest } from "./utils/BaseConsiderationTest.sol";

import { BaseOrderTest } from "./utils/BaseOrderTest.sol";

import {
    ConduitInterface
} from "../../contracts/interfaces/ConduitInterface.sol";

import { ConduitItemType } from "../../contracts/conduit/lib/ConduitEnums.sol";

import { TransferHelper } from "../../contracts/helpers/TransferHelper.sol";

import {
    TransferHelperItemWithRecipient
} from "../../contracts/helpers/TransferHelperStructs.sol";

import { TestERC20 } from "../../contracts/test/TestERC20.sol";

import { TestERC721 } from "../../contracts/test/TestERC721.sol";

import { TestERC1155 } from "../../contracts/test/TestERC1155.sol";

import { ConduitMock } from "../../contracts/test/ConduitMock.sol";

import {
    ConduitMockInvalidMagic
} from "../../contracts/test/ConduitMockInvalidMagic.sol";

import {
    ConduitMockRevertNoReason
} from "../../contracts/test/ConduitMockRevertNoReason.sol";
import {
    ConduitControllerMock
} from "../../contracts/test/ConduitControllerMock.sol";

import {
    InvalidERC721Recipient
} from "../../contracts/test/InvalidERC721Recipient.sol";

import {
    TokenTransferrerErrors
} from "../../contracts/interfaces/TokenTransferrerErrors.sol";

import {
    TransferHelperInterface
} from "../../contracts/interfaces/TransferHelperInterface.sol";

import {
    TransferHelperErrors
} from "../../contracts/interfaces/TransferHelperErrors.sol";

import {
    IERC721Receiver
} from "../../contracts/interfaces/IERC721Receiver.sol";

import {
    ERC721ReceiverMock
} from "../../contracts/test/ERC721ReceiverMock.sol";

import { TestERC20Panic } from "../../contracts/test/TestERC20Panic.sol";

contract TransferHelperMultipleRecipientsTest is BaseOrderTest {
    TransferHelper transferHelper;
    // Total supply of fungible tokens to be used in tests for all fungible tokens.
    uint256 constant TOTAL_FUNGIBLE_TOKENS = 1e6;
    // Total number of token identifiers to mint tokens for for ERC721s and ERC1155s.
    uint256 constant TOTAL_TOKEN_IDENTIFERS = 10;
    // Constant bytes used for expecting revert with no message.
    bytes constant REVERT_DATA_NO_MSG = "revert no message";
    ERC721ReceiverMock validERC721Receiver;
    ERC721ReceiverMock invalidERC721Receiver;
    InvalidERC721Recipient invalidRecipient;

    struct FromToBalance {
        // Balance of from address.
        uint256 from;
        // Balance of to address.
        uint256 to;
    }

    struct FuzzInputsCommon {
        // Indicates if a conduit should be used for the transfer
        bool useConduit;
        // Amounts that can be used for the amount field on TransferHelperItemWithRecipient
        uint256[10] amounts;
        // Identifiers that can be used for the identifier field on TransferHelperItemWithRecipient
        uint256[10] identifiers;
        // Indexes that can be used to select tokens from the arrays erc20s/erc721s/erc1155s
        uint256[10] tokenIndex;
        address[10] recipients;
    }

    function setUp() public override {
        super.setUp();
        _deployAndConfigurePrecompiledTransferHelper();
        vm.label(address(transferHelper), "transferHelper");

        // Mint initial tokens to alice for tests.
        for (uint256 tokenIdx = 0; tokenIdx < erc20s.length; tokenIdx++) {
            erc20s[tokenIdx].mint(alice, TOTAL_FUNGIBLE_TOKENS);
        }

        // Mint ERC721 and ERC1155 with token IDs 0 to TOTAL_TOKEN_IDENTIFERS - 1 to alice
        for (
            uint256 identifier = 0;
            identifier < TOTAL_TOKEN_IDENTIFERS;
            identifier++
        ) {
            for (uint256 tokenIdx = 0; tokenIdx < erc721s.length; tokenIdx++) {
                erc721s[tokenIdx].mint(alice, identifier);
            }
            for (uint256 tokenIdx = 0; tokenIdx < erc1155s.length; tokenIdx++) {
                erc1155s[tokenIdx].mint(
                    alice,
                    identifier,
                    TOTAL_FUNGIBLE_TOKENS
                );
            }
        }

        // Allow transfer helper to perform transfers for these addresses.
        _setApprovals(alice);
        _setApprovals(bob);
        _setApprovals(cal);

        // Open a channel for transfer helper on the conduit
        _updateConduitChannel(true);

        validERC721Receiver = new ERC721ReceiverMock(
            IERC721Receiver.onERC721Received.selector,
            ERC721ReceiverMock.Error.None
        );
        vm.label(address(validERC721Receiver), "valid ERC721 receiver");
        invalidERC721Receiver = new ERC721ReceiverMock(
            0xabcd0000,
            ERC721ReceiverMock.Error.RevertWithMessage
        );
        vm.label(
            address(invalidERC721Receiver),
            "invalid (error) ERC721 receiver"
        );

        invalidRecipient = new InvalidERC721Recipient();
        vm.label(
            address(invalidRecipient),
            "invalid ERC721 receiver (bad selector)"
        );
    }

    /**
     * @dev TransferHelper depends on precomputed Conduit creation code hash, which will differ
     * if tests are run with different compiler settings (which they are by default)
     */
    function _deployAndConfigurePrecompiledTransferHelper() public {
        transferHelper = TransferHelper(
            deployCode(
                "optimized-out/TransferHelper.sol/TransferHelper.json",
                abi.encode(address(conduitController))
            )
        );
    }

    // Helper functions

    function _setApprovals(address _owner) internal override {
        super._setApprovals(_owner);
        vm.startPrank(_owner);
        for (uint256 i = 0; i < erc20s.length; i++) {
            erc20s[i].approve(address(transferHelper), MAX_INT);
        }
        for (uint256 i = 0; i < erc1155s.length; i++) {
            erc1155s[i].setApprovalForAll(address(transferHelper), true);
        }
        for (uint256 i = 0; i < erc721s.length; i++) {
            erc721s[i].setApprovalForAll(address(transferHelper), true);
        }
        vm.stopPrank();
        // emit log_named_address(
        //     "Owner proxy approved for all tokens from",
        //     _owner
        // );
        // emit log_named_address(
        //     "Consideration approved for all tokens from",
        //     _owner
        // );
    }

    function _updateConduitChannel(bool open) internal {
        (address _conduit, ) = conduitController.getConduit(conduitKeyOne);
        vm.prank(address(conduitController));
        ConduitInterface(_conduit).updateChannel(address(transferHelper), open);
    }

    function _balanceOfTransferItemForAddress(
        TransferHelperItemWithRecipient memory item,
        address addr
    ) internal view returns (uint256) {
        if (item.itemType == ConduitItemType.ERC20) {
            return TestERC20(item.token).balanceOf(addr);
        } else if (item.itemType == ConduitItemType.ERC721) {
            return
                TestERC721(item.token).ownerOf(item.identifier) == addr ? 1 : 0;
        } else if (item.itemType == ConduitItemType.ERC1155) {
            return TestERC1155(item.token).balanceOf(addr, item.identifier);
        } else if (item.itemType == ConduitItemType.NATIVE) {
            // Balance for native does not matter as don't support native transfers so just return dummy value.
            return 0;
        }
        // Revert on unsupported ConduitItemType.
        revert();
    }

    function _balanceOfTransferItemForFromTo(
        TransferHelperItemWithRecipient memory item,
        address from
    ) internal view returns (FromToBalance memory) {
        return
            FromToBalance(
                _balanceOfTransferItemForAddress(item, from),
                _balanceOfTransferItemForAddress(item, item.recipient)
            );
    }

    function _performSingleItemTransferAndCheckBalances(
        TransferHelperItemWithRecipient memory item,
        address from,
        bool useConduit,
        bytes memory expectRevertData
    ) public {
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        items[0] = item;
        _performMultiItemTransferAndCheckBalances(
            items,
            from,
            useConduit,
            expectRevertData
        );
    }

    function _performMultiItemTransferAndCheckBalances(
        TransferHelperItemWithRecipient[] memory items,
        address from,
        bool useConduit,
        bytes memory expectRevertData
    ) public {
        vm.startPrank(from);

        // Get balances before transfer
        FromToBalance[] memory beforeTransferBalances = new FromToBalance[](
            items.length
        );
        for (uint256 i = 0; i < items.length; i++) {
            beforeTransferBalances[i] = _balanceOfTransferItemForFromTo(
                items[i],
                from
            );
        }

        // Register expected revert if present.
        if (
            // Compare hashes as we cannot directly compare bytes memory with bytes storage.
            keccak256(expectRevertData) == keccak256(REVERT_DATA_NO_MSG)
        ) {
            vm.expectRevert();
        } else if (expectRevertData.length > 0) {
            vm.expectRevert(expectRevertData);
        }
        // Perform transfer.
        transferHelper.bulkTransferToMultipleRecipients(
            items,
            useConduit ? conduitKeyOne : bytes32(0)
        );

        // Get balances after transfer
        FromToBalance[] memory afterTransferBalances = new FromToBalance[](
            items.length
        );
        for (uint256 i = 0; i < items.length; i++) {
            afterTransferBalances[i] = _balanceOfTransferItemForFromTo(
                items[i],
                from
            );
        }

        if (expectRevertData.length > 0) {
            // If revert is expected, balances should not have changed.
            for (uint256 i = 0; i < items.length; i++) {
                assert(
                    beforeTransferBalances[i].from ==
                        afterTransferBalances[i].from
                );
                assert(
                    beforeTransferBalances[i].to == afterTransferBalances[i].to
                );
            }
            return;
        }

        // Check after transfer balances are as expected by calculating difference against before transfer balances.
        for (uint256 i = 0; i < items.length; i++) {
            // ERC721 balance should only ever change by amount 1.
            uint256 amount = items[i].itemType == ConduitItemType.ERC721
                ? 1
                : items[i].amount;
            assertEq(
                afterTransferBalances[i].from,
                beforeTransferBalances[i].from - amount
            );
            assertEq(
                afterTransferBalances[i].to,
                beforeTransferBalances[i].to + amount
            );
        }

        vm.stopPrank();
    }

    function _performMultiItemTransferAndCheckBalances(
        TransferHelperItemWithRecipient[] memory items,
        address from,
        bool useConduit,
        bytes memory expectRevertDataWithConduit,
        bytes memory expectRevertDataWithoutConduit
    ) public {
        vm.startPrank(from);

        // Get balances before transfer
        FromToBalance[] memory beforeTransferBalances = new FromToBalance[](
            items.length
        );
        for (uint256 i = 0; i < items.length; i++) {
            beforeTransferBalances[i] = _balanceOfTransferItemForFromTo(
                items[i],
                from
            );
        }

        // Register expected revert if present.
        if (
            // Compare hashes as we cannot directly compare bytes memory with bytes storage.
            (keccak256(expectRevertDataWithConduit) ==
                keccak256(REVERT_DATA_NO_MSG) &&
                useConduit) ||
            (keccak256(expectRevertDataWithoutConduit) ==
                keccak256(REVERT_DATA_NO_MSG) &&
                !useConduit)
        ) {
            vm.expectRevert();
        } else if (expectRevertDataWithConduit.length > 0 && useConduit) {
            vm.expectRevert(expectRevertDataWithConduit);
        } else if (expectRevertDataWithoutConduit.length > 0 && !useConduit) {
            vm.expectRevert(expectRevertDataWithoutConduit);
        }
        // Perform transfer.
        transferHelper.bulkTransferToMultipleRecipients(
            items,
            useConduit ? conduitKeyOne : bytes32(0)
        );

        // Get balances after transfer
        FromToBalance[] memory afterTransferBalances = new FromToBalance[](
            items.length
        );
        for (uint256 i = 0; i < items.length; i++) {
            afterTransferBalances[i] = _balanceOfTransferItemForFromTo(
                items[i],
                from
            );
        }

        if (
            (expectRevertDataWithConduit.length > 0) ||
            (expectRevertDataWithoutConduit.length > 0)
        ) {
            // If revert is expected, balances should not have changed.
            for (uint256 i = 0; i < items.length; i++) {
                assert(
                    beforeTransferBalances[i].from ==
                        afterTransferBalances[i].from
                );
                assert(
                    beforeTransferBalances[i].to == afterTransferBalances[i].to
                );
            }
            return;
        }

        // Check after transfer balances are as expected by calculating difference against before transfer balances.
        for (uint256 i = 0; i < items.length; i++) {
            // ERC721 balance should only ever change by amount 1.
            uint256 amount = items[i].itemType == ConduitItemType.ERC721
                ? 1
                : items[i].amount;
            assertEq(
                afterTransferBalances[i].from,
                beforeTransferBalances[i].from - amount
            );
            assertEq(
                afterTransferBalances[i].to,
                beforeTransferBalances[i].to + amount
            );
        }

        vm.stopPrank();
    }

    function _makeSafeRecipient(address from, address fuzzRecipient)
        internal
        view
        returns (address)
    {
        return _makeSafeRecipient(from, fuzzRecipient, false);
    }

    function _makeSafeRecipient(
        address from,
        address fuzzRecipient,
        bool reverting
    ) internal view returns (address) {
        if (
            fuzzRecipient == address(validERC721Receiver) ||
            (reverting &&
                (fuzzRecipient == address(invalidERC721Receiver) ||
                    fuzzRecipient == address(invalidRecipient)))
        ) {
            return fuzzRecipient;
        } else if (
            fuzzRecipient == address(0) ||
            fuzzRecipient.code.length > 0 ||
            from == fuzzRecipient
        ) {
            return address(uint160(fuzzRecipient) + 1);
        }
        return fuzzRecipient;
    }

    function _getFuzzedTransferItem(
        address from,
        ConduitItemType itemType,
        uint256 fuzzAmount,
        uint256 fuzzIndex,
        uint256 fuzzIdentifier,
        address fuzzRecipient
    ) internal view returns (TransferHelperItemWithRecipient memory) {
        return
            _getFuzzedTransferItem(
                from,
                itemType,
                fuzzAmount,
                fuzzIndex,
                fuzzIdentifier,
                fuzzRecipient,
                false
            );
    }

    function _getFuzzedTransferItem(
        address from,
        ConduitItemType itemType,
        uint256 fuzzAmount,
        uint256 fuzzIndex,
        uint256 fuzzIdentifier,
        address fuzzRecipient,
        bool reverting
    ) internal view returns (TransferHelperItemWithRecipient memory) {
        uint256 amount = fuzzAmount % TOTAL_FUNGIBLE_TOKENS;
        uint256 identifier = fuzzIdentifier % TOTAL_TOKEN_IDENTIFERS;
        address recipient = _makeSafeRecipient(from, fuzzRecipient, reverting);
        if (itemType == ConduitItemType.ERC20) {
            uint256 index = fuzzIndex % erc20s.length;
            TestERC20 erc20 = erc20s[index];
            return
                TransferHelperItemWithRecipient(
                    itemType,
                    address(erc20),
                    identifier,
                    amount,
                    recipient
                );
        } else if (itemType == ConduitItemType.ERC1155) {
            uint256 index = fuzzIndex % erc1155s.length;
            TestERC1155 erc1155 = erc1155s[index];
            return
                TransferHelperItemWithRecipient(
                    itemType,
                    address(erc1155),
                    identifier,
                    amount,
                    recipient
                );
        } else if (itemType == ConduitItemType.NATIVE) {
            return
                TransferHelperItemWithRecipient(
                    itemType,
                    address(0),
                    identifier,
                    amount,
                    recipient
                );
        } else if (itemType == ConduitItemType.ERC721) {
            uint256 index = fuzzIndex % erc721s.length;
            return
                TransferHelperItemWithRecipient(
                    itemType,
                    address(erc721s[index]),
                    identifier,
                    1,
                    recipient
                );
        }
        revert();
    }

    function _getFuzzedERC721TransferItemWithAmountGreaterThan1(
        address from,
        uint256 fuzzAmount,
        uint256 fuzzIndex,
        uint256 fuzzIdentifier,
        address fuzzRecipient
    ) internal view returns (TransferHelperItemWithRecipient memory) {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            from,
            ConduitItemType.ERC721,
            fuzzAmount,
            fuzzIndex,
            fuzzIdentifier,
            fuzzRecipient
        );
        item.amount = 2 + (fuzzAmount % TOTAL_FUNGIBLE_TOKENS);
        return item;
    }

    function getSelector(bytes calldata returnData)
        public
        pure
        returns (bytes memory)
    {
        return returnData[0x84:0x88];
    }

    // Test successful transfers

    function testBulkTransferERC20(FuzzInputsCommon memory inputs) public {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC20,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            0,
            inputs.recipients[0]
        );

        _performSingleItemTransferAndCheckBalances(
            item,
            alice,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferERC721(FuzzInputsCommon memory inputs) public {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            inputs.recipients[0]
        );

        _performSingleItemTransferAndCheckBalances(
            item,
            alice,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferERC721toBobThenCal(FuzzInputsCommon memory inputs)
        public
    {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            bob
        );

        TransferHelperItemWithRecipient memory item2 = _getFuzzedTransferItem(
            bob,
            ConduitItemType.ERC721,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            cal
        );

        _performSingleItemTransferAndCheckBalances(
            item,
            alice,
            inputs.useConduit,
            ""
        );
        _performSingleItemTransferAndCheckBalances(
            item2,
            bob,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferERC1155(FuzzInputsCommon memory inputs) public {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC1155,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            inputs.recipients[0]
        );

        _performSingleItemTransferAndCheckBalances(
            item,
            alice,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferERC1155andERC721(FuzzInputsCommon memory inputs)
        public
    {
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](2);
        items[0] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC1155,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            inputs.recipients[0]
        );
        items[1] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            inputs.amounts[1],
            inputs.tokenIndex[1],
            inputs.identifiers[1],
            inputs.recipients[1]
        );

        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferERC1155andERC721andERC20(
        FuzzInputsCommon memory inputs
    ) public {
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](3);
        items[0] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC1155,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            inputs.recipients[0]
        );
        items[1] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            1,
            inputs.tokenIndex[1],
            inputs.identifiers[1],
            inputs.recipients[1]
        );
        items[2] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC20,
            inputs.amounts[2],
            inputs.tokenIndex[2],
            0,
            inputs.recipients[2]
        );

        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferMultipleERC721SameContract(
        FuzzInputsCommon memory inputs
    ) public {
        uint256 numItems = 3;
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](numItems);
        for (uint256 i = 0; i < numItems; i++) {
            items[i] = _getFuzzedTransferItem(
                alice,
                ConduitItemType.ERC721,
                inputs.amounts[i],
                // Same token index for all items since this is testing from same contract
                inputs.tokenIndex[0],
                // Each item has a different token identifier as alice only owns one ERC721 token
                // for each identifier for this particular contract
                i,
                inputs.recipients[0]
            );
        }

        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferMultipleERC721DifferentContracts(
        FuzzInputsCommon memory inputs
    ) public {
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](3);
        items[0] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            inputs.amounts[0],
            // Different token index for all items since this is testing from different contracts
            0,
            inputs.identifiers[0],
            inputs.recipients[0]
        );
        items[1] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            inputs.amounts[1],
            1,
            inputs.identifiers[1],
            inputs.recipients[1]
        );
        items[2] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            inputs.amounts[2],
            2,
            inputs.identifiers[2],
            inputs.recipients[2]
        );

        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferMultipleERC721andMultipleERC1155(
        FuzzInputsCommon memory inputs
    ) public {
        uint256 numItems = 6;
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](numItems);

        // Fill items such that the first floor(numItems / 2) items are ERC1155 and the remaining
        // items are ERC721
        for (uint256 i = 0; i < numItems; i++) {
            if (i < numItems / 2) {
                items[i] = _getFuzzedTransferItem(
                    alice,
                    ConduitItemType.ERC1155,
                    inputs.amounts[i],
                    // Ensure each item is from a different contract
                    i,
                    inputs.identifiers[i],
                    inputs.recipients[i]
                );
            } else {
                items[i] = _getFuzzedTransferItem(
                    alice,
                    ConduitItemType.ERC721,
                    inputs.amounts[i],
                    i,
                    inputs.identifiers[i],
                    inputs.recipients[i]
                );
            }
        }

        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            inputs.useConduit,
            ""
        );
    }

    function testBulkTransferERC7211NotUsingConduit(
        FuzzInputsCommon memory inputs
    ) public {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            1,
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            inputs.recipients[0]
        );

        _performSingleItemTransferAndCheckBalances(item, alice, false, "");
    }

    function testBulkTransferERC721ToContractRecipientNotUsingConduit(
        FuzzInputsCommon memory inputs
    ) public {
        // ERC721ReceiverMock erc721Receiver = new ERC721ReceiverMock(
        //     IERC721Receiver.onERC721Received.selector,
        //     ERC721ReceiverMock.Error.None
        // );

        uint256 numItems = 6;
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](numItems);

        for (uint256 i = 0; i < numItems; i++) {
            items[i] = _getFuzzedTransferItem(
                alice,
                ConduitItemType.ERC721,
                1,
                inputs.tokenIndex[i],
                i,
                address(validERC721Receiver)
            );
        }

        _performMultiItemTransferAndCheckBalances(items, alice, false, "");
    }

    function testBulkTransferERC721AndERC20NotUsingConduit(
        FuzzInputsCommon memory inputs
    ) public {
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](2);
        items[0] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            1,
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            inputs.recipients[0]
        );

        items[1] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC20,
            inputs.amounts[1],
            inputs.tokenIndex[1],
            0,
            inputs.recipients[1]
        );

        _performMultiItemTransferAndCheckBalances(items, alice, false, "");
    }

    // Test reverts

    function testRevertBulkTransferERC20InvalidIdentifier(
        FuzzInputsCommon memory inputs
    ) public {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC20,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            5,
            inputs.recipients[0]
        );
        // Ensure ERC20 identifier is at least 1
        item.identifier += 1;

        _performSingleItemTransferAndCheckBalances(
            item,
            alice,
            false,
            abi.encodePacked(
                TransferHelperErrors.InvalidERC20Identifier.selector
            )
        );
    }

    function testRevertBulkTransferERC721InvalidRecipient(
        FuzzInputsCommon memory inputs
    ) public {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            1,
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            address(invalidRecipient),
            true
        );

        _performSingleItemTransferAndCheckBalances(
            item,
            alice,
            false,
            abi.encodeWithSignature(
                "InvalidERC721Recipient(address)",
                invalidRecipient
            )
        );
    }

    function testRevertBulkTransferETHonly(FuzzInputsCommon memory inputs)
        public
    {
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        items[0] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.NATIVE,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            bob
        );

        bytes memory returnedData;
        try
            transferHelper.bulkTransferToMultipleRecipients(
                items,
                conduitKeyOne
            )
        returns (
            bytes4 /* magicValue */
        ) {} catch (bytes memory reason) {
            returnedData = this.getSelector(reason);
        }

        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            inputs.useConduit,
            abi.encodeWithSignature(
                "ConduitErrorRevertBytes(bytes,bytes32,address)",
                returnedData,
                conduitKeyOne,
                conduit
            ),
            abi.encodePacked(TransferHelperErrors.InvalidItemType.selector)
        );
    }

    function testRevertBulkTransferETHandERC721(FuzzInputsCommon memory inputs)
        public
    {
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](2);
        items[0] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.NATIVE,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            bob
        );
        items[1] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            1,
            inputs.tokenIndex[1],
            inputs.identifiers[1],
            bob
        );

        bytes memory returnedData;
        try
            transferHelper.bulkTransferToMultipleRecipients(
                items,
                conduitKeyOne
            )
        returns (
            bytes4 /* magicValue */
        ) {} catch (bytes memory reason) {
            returnedData = this.getSelector(reason);
        }

        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            inputs.useConduit,
            abi.encodeWithSignature(
                "ConduitErrorRevertBytes(bytes,bytes32,address)",
                returnedData,
                conduitKeyOne,
                conduit
            ),
            abi.encodePacked(TransferHelperErrors.InvalidItemType.selector)
        );
    }

    function testRevertBulkTransferERC721AmountMoreThan1UsingConduit(
        FuzzInputsCommon memory inputs,
        uint256 invalidAmount
    ) public {
        vm.assume(invalidAmount > 1);

        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        TransferHelperItemWithRecipient
            memory item = _getFuzzedERC721TransferItemWithAmountGreaterThan1(
                alice,
                invalidAmount,
                inputs.tokenIndex[0],
                inputs.identifiers[0],
                bob
            );

        items[0] = item;
        bytes memory returnedData;
        try
            transferHelper.bulkTransferToMultipleRecipients(
                items,
                conduitKeyOne
            )
        returns (
            bytes4 /* magicValue */
        ) {} catch (bytes memory reason) {
            returnedData = this.getSelector(reason);
        }
        _performSingleItemTransferAndCheckBalances(
            item,
            alice,
            true,
            abi.encodeWithSignature(
                "ConduitErrorRevertBytes(bytes,bytes32,address)",
                returnedData,
                conduitKeyOne,
                conduit
            )
        );
    }

    function testRevertBulkTransferERC721AmountMoreThan1AndERC20UsingConduit(
        FuzzInputsCommon memory inputs
    ) public {
        vm.assume(inputs.amounts[0] > 0);

        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](2);
        items[0] = _getFuzzedERC721TransferItemWithAmountGreaterThan1(
            alice,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            bob
        );

        items[1] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC20,
            inputs.amounts[1],
            inputs.tokenIndex[1],
            inputs.identifiers[1],
            bob
        );

        bytes memory returnedData;
        try
            transferHelper.bulkTransferToMultipleRecipients(
                items,
                conduitKeyOne
            )
        returns (
            bytes4 /* magicValue */
        ) {} catch (bytes memory reason) {
            returnedData = this.getSelector(reason);
        }

        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            true,
            abi.encodeWithSignature(
                "ConduitErrorRevertBytes(bytes,bytes32,address)",
                returnedData,
                conduitKeyOne,
                conduit
            )
        );
    }

    function testRevertBulkTransferNotOpenConduitChannel(
        FuzzInputsCommon memory inputs
    ) public {
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        items[0] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC20,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            bob
        );

        _updateConduitChannel(false);

        bytes memory returnedData = abi.encodeWithSelector(
            0x93daadf2,
            address(transferHelper)
        );

        _performSingleItemTransferAndCheckBalances(
            items[0],
            alice,
            true,
            abi.encodeWithSignature(
                "ConduitErrorRevertBytes(bytes,bytes32,address)",
                returnedData,
                conduitKeyOne,
                conduit
            )
        );
    }

    function testRevertBulkTransferUnknownConduit(
        FuzzInputsCommon memory inputs,
        bytes32 fuzzConduitKey
    ) public {
        // Assume fuzzConduitKey is not equal to TransferHelper's value for "no conduit".
        vm.assume(
            fuzzConduitKey != bytes32(0) && fuzzConduitKey != conduitKeyOne
        );

        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        items[0] = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC20,
            inputs.amounts[0],
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            bob
        );

        // Reassign the conduit key that gets passed into TransferHelper to fuzzConduitKey.
        conduitKeyOne = fuzzConduitKey;

        (address unknownConduitAddress, ) = conduitController.getConduit(
            conduitKeyOne
        );
        vm.label(unknownConduitAddress, "unknown conduit");

        vm.expectRevert();
        vm.prank(alice);
        transferHelper.bulkTransferToMultipleRecipients(items, conduitKeyOne);
    }

    function testRevertInvalidERC721Receiver(FuzzInputsCommon memory inputs)
        public
    {
        TransferHelperItemWithRecipient memory item = _getFuzzedTransferItem(
            alice,
            ConduitItemType.ERC721,
            1,
            inputs.tokenIndex[0],
            inputs.identifiers[0],
            address(invalidERC721Receiver),
            true
        );
        _performSingleItemTransferAndCheckBalances(
            item,
            alice,
            false,
            abi.encodeWithSignature(
                "ERC721ReceiverErrorRevertString(string,address,address,uint256)",
                "ERC721ReceiverMock: reverting",
                invalidERC721Receiver,
                alice,
                item.identifier
            )
        );
    }

    function testRevertStringErrorWithConduit() public {
        TransferHelperItemWithRecipient
            memory item = TransferHelperItemWithRecipient(
                ConduitItemType.ERC721,
                address(erc721s[0]),
                5,
                1,
                alice
            );

        (address _conduit, ) = conduitController.getConduit(conduitKeyOne);
        // Attempt to transfer ERC721 tokens from bob to alice
        // Expect revert since alice owns the tokens
        _performSingleItemTransferAndCheckBalances(
            item,
            bob,
            true,
            abi.encodeWithSignature(
                "ConduitErrorRevertString(string,bytes32,address)",
                "WRONG_FROM",
                conduitKeyOne,
                _conduit
            )
        );
    }

    function testRevertPanicErrorWithConduit() public {
        // Create ERC20 token that reverts with a panic when calling transferFrom.
        TestERC20Panic panicERC20 = new TestERC20Panic();

        // Mint ERC20 tokens to alice.
        panicERC20.mint(alice, 10);

        // Approve the ERC20 tokens
        panicERC20.approve(alice, 10);

        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        items[0] = TransferHelperItemWithRecipient(
            ConduitItemType.ERC20,
            address(panicERC20),
            0,
            10,
            bob
        );

        (address _conduit, ) = conduitController.getConduit(conduitKeyOne);
        bytes memory panicError = abi.encodeWithSelector(0x4e487b71, 18);

        // Revert with panic error when calling execute via conduit
        _performMultiItemTransferAndCheckBalances(
            items,
            alice,
            true,
            abi.encodeWithSignature(
                "ConduitErrorRevertBytes(bytes,bytes32,address)",
                panicError,
                conduitKeyOne,
                _conduit
            )
        );
    }

    function testRevertInvalidConduitMagicValue() public {
        // Deploy mock conduit controller
        ConduitControllerMock mockConduitController = new ConduitControllerMock(
            2 // ConduitMockInvalidMagic
        );

        // Create conduit key using alice's address
        bytes32 conduitKeyAlice = bytes32(
            uint256(uint160(address(alice))) << 96
        );

        // Deploy mock transfer helper that takes in the mock conduit controller
        TransferHelper mockTransferHelper = TransferHelper(
            deployCode(
                "optimized-out/TransferHelper.sol/TransferHelper.json",
                abi.encode(address(mockConduitController))
            )
        );
        vm.label(address(mockTransferHelper), "mock transfer helper");

        vm.startPrank(alice);

        // Create the mock conduit by calling the mock conduit controller
        ConduitMockInvalidMagic mockConduit = ConduitMockInvalidMagic(
            mockConduitController.createConduit(conduitKeyAlice, address(alice))
        );
        vm.label(address(mockConduit), "mock conduit");

        bytes32 conduitCodeHash = address(mockConduit).codehash;
        emit log_named_bytes32("conduit code hash", conduitCodeHash);

        // Assert the conduit key derived from the conduit address
        // matches alice's conduit key
        bytes32 mockConduitKey = mockConduitController.getKey(
            address(mockConduit)
        );

        assertEq(mockConduitKey, conduitKeyAlice);

        // Create item to transfer
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        items[0] = TransferHelperItemWithRecipient(
            ConduitItemType.ERC721,
            address(erc721s[0]),
            5,
            1,
            bob
        );

        (address _conduit, bool exists) = mockConduitController.getConduit(
            conduitKeyAlice
        );

        assertEq(address(mockConduit), _conduit);
        assertEq(exists, true);

        vm.expectRevert(
            abi.encodeWithSignature(
                "InvalidConduit(bytes32,address)",
                conduitKeyAlice,
                mockConduit
            )
        );
        mockTransferHelper.bulkTransferToMultipleRecipients(
            items,
            conduitKeyAlice
        );
        vm.stopPrank();
    }

    function testRevertNoErrorString() public {
        // Deploy mock conduit controller
        ConduitControllerMock mockConduitController = new ConduitControllerMock(
            1 // ConduitMockRevertNoReason
        );

        // Create conduit key using alice's address
        bytes32 conduitKeyAlice = bytes32(
            uint256(uint160(address(alice))) << 96
        );

        // Deploy mock transfer helper that takes in the mock conduit controller
        TransferHelper mockTransferHelper = TransferHelper(
            deployCode(
                "optimized-out/TransferHelper.sol/TransferHelper.json",
                abi.encode(address(mockConduitController))
            )
        );
        vm.label(address(mockTransferHelper), "mock transfer helper");

        vm.startPrank(alice);

        // Create the mock conduit by calling the mock conduit controller
        ConduitMockRevertNoReason mockConduit = ConduitMockRevertNoReason(
            mockConduitController.createConduit(conduitKeyAlice, address(alice))
        );
        vm.label(address(mockConduit), "mock conduit");

        bytes32 conduitCodeHash = address(mockConduit).codehash;
        emit log_named_bytes32("conduit code hash", conduitCodeHash);

        // Assert the conduit key derived from the conduit address
        // matches alice's conduit key
        bytes32 mockConduitKey = mockConduitController.getKey(
            address(mockConduit)
        );

        assertEq(mockConduitKey, conduitKeyAlice);

        // Create item to transfer
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        items[0] = TransferHelperItemWithRecipient(
            ConduitItemType.ERC721,
            address(erc721s[0]),
            5,
            1,
            bob
        );

        (address _conduit, bool exists) = mockConduitController.getConduit(
            conduitKeyAlice
        );

        assertEq(address(mockConduit), _conduit);
        assertEq(exists, true);

        vm.expectRevert(
            abi.encodeWithSignature(
                "ConduitErrorRevertBytes(bytes,bytes32,address)",
                "",
                conduitKeyAlice,
                mockConduit
            )
        );
        mockTransferHelper.bulkTransferToMultipleRecipients(
            items,
            conduitKeyAlice
        );
        vm.stopPrank();
    }

    function testRevertWithData() public {
        // Deploy mock conduit controller
        ConduitControllerMock mockConduitController = new ConduitControllerMock(
            3 // ConduitMockRevertBytes
        );

        // Create conduit key using alice's address
        bytes32 conduitKeyAlice = bytes32(
            uint256(uint160(address(alice))) << 96
        );

        // Deploy mock transfer helper that takes in the mock conduit controller
        TransferHelper mockTransferHelper = TransferHelper(
            deployCode(
                "optimized-out/TransferHelper.sol/TransferHelper.json",
                abi.encode(address(mockConduitController))
            )
        );
        vm.label(address(mockTransferHelper), "mock transfer helper");

        vm.startPrank(alice);

        // Create the mock conduit by calling the mock conduit controller
        ConduitMockInvalidMagic mockConduit = ConduitMockInvalidMagic(
            mockConduitController.createConduit(conduitKeyAlice, address(alice))
        );
        vm.label(address(mockConduit), "mock conduit");

        bytes32 conduitCodeHash = address(mockConduit).codehash;
        emit log_named_bytes32("conduit code hash", conduitCodeHash);

        // Assert the conduit key derived from the conduit address
        // matches alice's conduit key
        bytes32 mockConduitKey = mockConduitController.getKey(
            address(mockConduit)
        );

        assertEq(mockConduitKey, conduitKeyAlice);

        // Create item to transfer
        TransferHelperItemWithRecipient[]
            memory items = new TransferHelperItemWithRecipient[](1);
        items[0] = TransferHelperItemWithRecipient(
            ConduitItemType.ERC721,
            address(erc721s[0]),
            5,
            1,
            bob
        );

        (address _conduit, bool exists) = mockConduitController.getConduit(
            conduitKeyAlice
        );

        assertEq(address(mockConduit), _conduit);
        assertEq(exists, true);

        bytes memory returnedData;
        try
            mockTransferHelper.bulkTransferToMultipleRecipients(
                items,
                conduitKeyAlice
            )
        returns (
            bytes4 /* magicValue */
        ) {} catch (bytes memory reason) {
            returnedData = this.getSelector(reason);
        }
        vm.expectRevert(
            abi.encodeWithSignature(
                "ConduitErrorRevertBytes(bytes,bytes32,address)",
                returnedData,
                conduitKeyAlice,
                mockConduit
            )
        );
        mockTransferHelper.bulkTransferToMultipleRecipients(
            items,
            conduitKeyAlice
        );
        vm.stopPrank();
    }
}