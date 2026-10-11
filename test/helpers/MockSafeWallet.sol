// SPDX-License-Identifier: MIT
pragma solidity ^0.8.37;

/// @notice Minimal singleton code target used by Safe-wallet authority tests.
contract MockSafeSingleton {}

/// @notice Mutable Safe-compatible wallet used by deployment and authority tests.
contract MockSafeWallet {
    address[] private _owners;
    mapping(address => bool) private _isOwner;
    uint256 private _threshold;
    address private _singleton;
    string private _version = "1.5.0";
    uint8 public ownerResponseMode;

    constructor(address singleton_, address[] memory owners_, uint256 threshold_) {
        _singleton = singleton_;
        replaceOwners(owners_, threshold_);
    }

    function VERSION() external view returns (string memory) {
        return _version;
    }

    function masterCopy() external view returns (address) {
        return _singleton;
    }

    function getOwners() external view returns (address[] memory) {
        return _owners;
    }

    function getThreshold() external view returns (uint256) {
        return _threshold;
    }

    function isOwner(address account) external view returns (bool) {
        if (ownerResponseMode == 1) revert("mock isOwner revert");
        if (ownerResponseMode == 2) {
            assembly {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (ownerResponseMode == 3) {
            assembly {
                for {} 1 {} {}
            }
        }
        return _isOwner[account];
    }

    function replaceOwners(address[] memory owners_, uint256 threshold_) public {
        for (uint256 i; i < _owners.length; ++i) {
            _isOwner[_owners[i]] = false;
        }
        delete _owners;
        for (uint256 i; i < owners_.length; ++i) {
            _owners.push(owners_[i]);
            _isOwner[owners_[i]] = true;
        }
        _threshold = threshold_;
    }

    function setSingleton(address singleton_) external {
        _singleton = singleton_;
    }

    function setVersion(string calldata version_) external {
        _version = version_;
    }

    function setOwnerResponseMode(uint8 mode) external {
        ownerResponseMode = mode;
    }
}

library MockSafeWalletFactory {
    function deploy(address owner) internal returns (address) {
        address[] memory owners = new address[](1);
        owners[0] = owner;
        return address(new MockSafeWallet(address(new MockSafeSingleton()), owners, 1));
    }

    function deploy(address owner, address additionalOwner) internal returns (address) {
        if (additionalOwner == address(0) || additionalOwner == owner) return deploy(owner);
        address[] memory owners = new address[](2);
        owners[0] = owner;
        owners[1] = additionalOwner;
        return address(new MockSafeWallet(address(new MockSafeSingleton()), owners, 2));
    }
}
