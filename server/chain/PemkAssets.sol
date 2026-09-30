// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title PEMK Assets - the on-chain receipt of what the PEMK server proved.
/// @notice The PEMK server owns every Pokemon (its registry, its trades). This contract
///         mirrors the ones its policy tokenizes: one token per Pokemon uid (the token id
///         IS the uid), held by the vault and attributed to a PEMK account number. Every
///         write is the operator's - the server's relayer key - so a token appears only
///         when the server proved the Pokemon, moves only when a trade committed, and
///         freezes only when the server quarantined it. The supply caps are the one thing
///         the chain enforces on its own: once a species reaches its cap, nobody mints
///         another, the operator included.
///
///         ERC-721 READ subset (name, symbol, ownerOf, balanceOf, Transfer) so explorers
///         and wallets list the tokens; approvals and player-held transfers are a later
///         layer (docs/CHAIN-DESIGN.md), when a player links a wallet.
contract PemkAssets {
    string public constant name   = "PEMK Assets";
    string public constant symbol = "PEMK";

    uint8 public constant KIND_MONSTER = 0;
    uint8 public constant KIND_CARD    = 1;

    struct Asset {
        uint64 account;   // the PEMK account that owns it
        uint8  kind;      // KIND_MONSTER | KIND_CARD
        bool   shiny;
        bool   frozen;    // quarantined on the server
        string species;
        string origin;    // wild_caught | wild | client | "" - what the server knew at mint
    }

    address public owner;   // the operator (the relayer's key)
    address public vault;   // where every token sits until players hold wallets

    mapping(uint256 => Asset)   private _assets;
    mapping(uint256 => address) private _holders;
    mapping(address => uint256) private _balances;
    mapping(bytes32 => uint32)  private _caps;     // keccak(species) -> cap (0 = uncapped)
    mapping(bytes32 => uint32)  private _minted;   // keccak(species) -> minted so far
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Minted(uint256 indexed tokenId, uint64 indexed account, uint8 kind, string species, bool shiny, string origin);
    event Moved(uint256 indexed tokenId, uint64 indexed fromAccount, uint64 indexed toAccount, string ref);
    event Frozen(uint256 indexed tokenId, bool frozen, string reason);
    event CapSet(string species, uint32 cap);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    modifier onlyOwner() {
        require(msg.sender == owner, "not operator");
        _;
    }

    constructor() {
        owner = msg.sender;
        vault = msg.sender;
    }

    // --- reads ---------------------------------------------------------------

    function exists(uint256 tokenId) public view returns (bool) {
        return _holders[tokenId] != address(0);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        require(exists(tokenId), "no token");
        return _holders[tokenId];
    }

    function balanceOf(address holder) external view returns (uint256) {
        require(holder != address(0), "zero address");
        return _balances[holder];
    }

    function accountOf(uint256 tokenId) external view returns (uint64) {
        require(exists(tokenId), "no token");
        return _assets[tokenId].account;
    }

    function assetOf(uint256 tokenId) external view returns (Asset memory) {
        require(exists(tokenId), "no token");
        return _assets[tokenId];
    }

    function frozen(uint256 tokenId) external view returns (bool) {
        require(exists(tokenId), "no token");
        return _assets[tokenId].frozen;
    }

    /// @return minted how many of the species exist, and cap its limit (0 = none).
    function supplyOf(string calldata species) external view returns (uint32 minted, uint32 cap) {
        bytes32 k = keccak256(bytes(species));
        return (_minted[k], _caps[k]);
    }

    // --- writes (operator only) -----------------------------------------------

    /// @notice A cap can only be set at or above what is already minted, and never
    ///         lowered below it; 0 removes it.
    function setCap(string calldata species, uint32 cap) external onlyOwner {
        bytes32 k = keccak256(bytes(species));
        require(cap == 0 || cap >= _minted[k], "below minted");
        _caps[k] = cap;
        emit CapSet(species, cap);
    }

    function mint(uint256 tokenId, uint64 account, uint8 kind, string calldata species, bool shiny, string calldata origin)
        external onlyOwner
    {
        require(!exists(tokenId), "minted");
        require(account != 0, "no account");
        bytes32 k = keccak256(bytes(species));
        require(_caps[k] == 0 || _minted[k] < _caps[k], "supply");
        _minted[k] += 1;
        totalSupply += 1;
        _holders[tokenId] = vault;
        _balances[vault] += 1;
        _assets[tokenId] = Asset({ account: account, kind: kind, shiny: shiny, frozen: false, species: species, origin: origin });
        emit Transfer(address(0), vault, tokenId);
        emit Minted(tokenId, account, kind, species, shiny, origin);
    }

    /// @notice A committed trade or sale. Idempotent for the relayer: moving a token to
    ///         the account that already holds it is a no-op, not an error.
    function move(uint256 tokenId, uint64 toAccount, string calldata ref) external onlyOwner {
        require(exists(tokenId), "no token");
        require(toAccount != 0, "no account");
        require(!_assets[tokenId].frozen, "frozen");
        uint64 fromAccount = _assets[tokenId].account;
        if (fromAccount == toAccount) return;
        _assets[tokenId].account = toAccount;
        emit Moved(tokenId, fromAccount, toAccount, ref);
    }

    function setFrozen(uint256 tokenId, bool isFrozen, string calldata reason) external onlyOwner {
        require(exists(tokenId), "no token");
        if (_assets[tokenId].frozen == isFrozen) return;
        _assets[tokenId].frozen = isFrozen;
        emit Frozen(tokenId, isFrozen, reason);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero address");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
        vault = newOwner;
    }
}
