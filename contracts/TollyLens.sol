// SPDX-License-Identifier: MIT
// Copyright (c) 2026 TollyLabs
pragma solidity 0.8.26;

interface IDeployerLens {
    function forgesCount() external view returns (uint256);
    function allForges(uint256) external view returns (address);
    function universalForge() external view returns (address);
    function routerForge() external view returns (address);
    function liquidityForgeFactory() external view returns (address);
}

interface IForgeLens {
    function toolsCount() external view returns (uint256);
    function allTools(uint256) external view returns (address);
}

interface IUniversalLens {
    function universalBurnersCount() external view returns (uint256);
    function allUniversalBurners(uint256) external view returns (address);
    function dcaTreasuriesCount() external view returns (uint256);
    function allDcaTreasuries(uint256) external view returns (address);
}

interface IRouterForgeLens {
    function routersCount() external view returns (uint256);
    function allRouters(uint256) external view returns (address);
    function liquidityForgesCount() external view returns (uint256);
    function allLiquidityForges(uint256) external view returns (address);
}

interface IToolLens {
    function projectToken() external view returns (address);
}

interface ILockableLens {
    function configurationLocked() external view returns (bool);
}

interface ILockableDcaLens {
    function strategyLocked() external view returns (bool);
}

interface IRouterLens {
    function allocationsCount() external view returns (uint256);
    function allocations(uint256) external view returns (uint8 kind, uint16 bps, address dest);
}

interface IFurnaceLens {
    function projectContribution(address) external view returns (uint256);
}

/// @title  TollyLens
/// @author TollyLabs
/// @notice Read-only aggregator for the dashboard frontend. Converts the
///         protocol's enumerable factory arrays into a small number of cheap
///         `eth_call`s so a backend-less frontend can render hundreds of
///         projects without excessive RPC load.
/// @dev    Reads the deployed suite only and never writes. It holds no funds,
///         has no owner and no privileged caller, and nothing in the protocol
///         reads it back, so it can be deployed or replaced at any time
///         without touching anything else.
///
///         Frontend flow (RPC-light):
///           boot     -> stats()          (composition counts, O(1))
///                    -> contributions()  (every project: token, tolls, tool bitmap; no strings)
///                    -> meta(pageTokens) (symbol/name for the visible page only)
///           paginate -> meta(pageTokens) (in-memory sort/filter; one call per page)
///           steady   -> events and a heartbeat drive updates; contributions() is
///                       re-called only when a new project joins.
///
///         Tool bitmap (flags): bit0 BURN, bit1 SPLIT (router), bit2 LIQUIDITY, bit3 DCA.
contract TollyLens {
    uint8 public constant BURN = 1;
    uint8 public constant SPLIT = 2;
    uint8 public constant LIQUIDITY = 4;
    uint8 public constant DCA = 8;

    IDeployerLens public immutable deployer;
    IFurnaceLens public immutable furnace;

    constructor(address _deployer, address _furnace) {
        deployer = IDeployerLens(_deployer);
        furnace = IFurnaceLens(_furnace);
    }

    /// @notice The four composition counts for the dashboard headline.
    /// @dev    Sums of the enumerable array lengths; cost is independent of
    ///         the number of projects. burners, routers, liquidity and dca
    ///         are instance counts, not distinct-project counts.
    /// @return burners Number of burner tool instances (forge tools plus universal burners).
    /// @return routers Number of revenue router instances.
    /// @return liquidity Number of liquidity forge instances.
    /// @return dca Number of DCA treasury instances.
    function stats() external view returns (uint256 burners, uint256 routers, uint256 liquidity, uint256 dca) {
        uint256 nf = deployer.forgesCount();
        for (uint256 i; i < nf; ++i) {
            burners += IForgeLens(deployer.allForges(i)).toolsCount();
        }
        IUniversalLens uf = IUniversalLens(deployer.universalForge());
        burners += uf.universalBurnersCount();
        dca = uf.dcaTreasuriesCount();
        IRouterForgeLens rf = IRouterForgeLens(deployer.routerForge());
        IRouterForgeLens lff = IRouterForgeLens(deployer.liquidityForgeFactory());
        routers = rf.routersCount();
        liquidity = lff.liquidityForgesCount();
    }

    /// @notice Returns every distinct project token in one call, with its
    ///         toll contribution and a bitmap of which tools it runs.
    /// @dev    Deliberately string-free to keep the payload small. The
    ///         frontend sorts, filters and paginates the result in memory,
    ///         and fetches `meta()` only for the page it displays.
    /// @return tokens Distinct project token addresses.
    /// @return tolls Each token's cumulative toll contribution, from the furnace.
    /// @return flags Each token's tool bitmap (see the contract-level NatSpec for bit assignments).
    function contributions()
        external
        view
        returns (address[] memory tokens, uint256[] memory tolls, uint8[] memory flags)
    {
        uint256 cap = _totalTools();
        address[] memory tmpTok = new address[](cap);
        uint8[] memory tmpFlag = new uint8[](cap);
        uint256 n;

        uint256 nf = deployer.forgesCount();
        for (uint256 i; i < nf; ++i) {
            IForgeLens forge = IForgeLens(deployer.allForges(i));
            uint256 nt = forge.toolsCount();
            for (uint256 j; j < nt; ++j) {
                n = _mark(tmpTok, tmpFlag, n, _tokenOf(forge.allTools(j)), BURN);
            }
        }

        IUniversalLens uf = IUniversalLens(deployer.universalForge());
        uint256 nub = uf.universalBurnersCount();
        for (uint256 i; i < nub; ++i) {
            n = _mark(tmpTok, tmpFlag, n, _tokenOf(uf.allUniversalBurners(i)), BURN);
        }
        uint256 nd = uf.dcaTreasuriesCount();
        for (uint256 i; i < nd; ++i) {
            n = _mark(tmpTok, tmpFlag, n, _tokenOf(uf.allDcaTreasuries(i)), DCA);
        }

        IRouterForgeLens rf = IRouterForgeLens(deployer.routerForge());
        IRouterForgeLens lff = IRouterForgeLens(deployer.liquidityForgeFactory());
        uint256 nr = rf.routersCount();
        for (uint256 i; i < nr; ++i) {
            n = _mark(tmpTok, tmpFlag, n, _tokenOf(rf.allRouters(i)), SPLIT);
        }
        uint256 nl = lff.liquidityForgesCount();
        for (uint256 i; i < nl; ++i) {
            n = _mark(tmpTok, tmpFlag, n, _tokenOf(lff.allLiquidityForges(i)), LIQUIDITY);
        }

        tokens = new address[](n);
        tolls = new uint256[](n);
        flags = new uint8[](n);
        for (uint256 i; i < n; ++i) {
            tokens[i] = tmpTok[i];
            flags[i] = tmpFlag[i];
            tolls[i] = furnace.projectContribution(tmpTok[i]);
        }
    }

    /// @notice A bounded window of the raw tool enumeration, so the aggregate
    ///         can be read at any scale.
    /// @dev    `contributions()` dedups on-chain with a linear scan per token
    ///         (O(n^2)), which is acceptable for the hundreds of tokens it was
    ///         designed for but exceeds the RPC gas cap for a single
    ///         `eth_call` somewhere in the low thousands of tools. This
    ///         function performs no dedup: it returns each tool's (token,
    ///         toll, flag) for the flat index range [offset, offset+limit),
    ///         plus the total tool count. The caller pages through the
    ///         result and merges duplicate tokens by OR-ing their flags in
    ///         memory, the same step the frontend already performs for
    ///         sorting and filtering.
    ///
    ///         Cost is O(limit * forgesCount) per call, with no full-array
    ///         build and no O(n^2) term. forgesCount is the number of
    ///         connected launchpads, which is small, not the number of
    ///         tokens. A token with two tools appears in two entries,
    ///         possibly on different pages; merging by token address is the
    ///         caller's responsibility.
    /// @param  offset Start index into the flat tool enumeration.
    /// @param  limit  Maximum number of entries to return.
    /// @return tokens Project token address for each tool in the window.
    /// @return tolls Each entry's toll contribution, from the furnace.
    /// @return flags Each entry's single-tool flag.
    /// @return total Total number of tools across all registries.
    function contributionsPaged(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory tokens, uint256[] memory tolls, uint8[] memory flags, uint256 total)
    {
        total = _totalTools();
        if (offset >= total || limit == 0) return (new address[](0), new uint256[](0), new uint8[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;

        tokens = new address[](count);
        tolls = new uint256[](count);
        flags = new uint8[](count);

        for (uint256 k = offset; k < end; ++k) {
            (address tool, uint8 flag) = _toolAt(k);
            address token = _tokenOf(tool);
            uint256 w = k - offset;
            tokens[w] = token;
            flags[w] = flag;
            tolls[w] = furnace.projectContribution(token);
        }
    }

    /// @dev Returns the tool at flat index `k` across the concatenated
    ///      registries, and its category flag. Enumeration order matches
    ///      `contributions()`: forge tools, universal burners, dca, routers,
    ///      liquidity.
    function _toolAt(uint256 k) private view returns (address tool, uint8 flag) {
        // Section 1: forge tools, nested per forge. forgesCount is small, so
        // walking each forge to locate the one containing `k` is inexpensive.
        uint256 nf = deployer.forgesCount();
        for (uint256 i; i < nf; ++i) {
            IForgeLens forge = IForgeLens(deployer.allForges(i));
            uint256 nt = forge.toolsCount();
            if (k < nt) return (forge.allTools(k), BURN);
            k -= nt;
        }
        IUniversalLens uf = IUniversalLens(deployer.universalForge());
        uint256 nub = uf.universalBurnersCount();
        if (k < nub) return (uf.allUniversalBurners(k), BURN);
        k -= nub;
        uint256 nd = uf.dcaTreasuriesCount();
        if (k < nd) return (uf.allDcaTreasuries(k), DCA);
        k -= nd;
        IRouterForgeLens rf = IRouterForgeLens(deployer.routerForge());
        uint256 nr = rf.routersCount();
        if (k < nr) return (rf.allRouters(k), SPLIT);
        k -= nr;
        IRouterForgeLens lff = IRouterForgeLens(deployer.liquidityForgeFactory());
        return (lff.allLiquidityForges(k), LIQUIDITY);
    }

    /// @notice Returns `symbol()` and `name()` for a set of tokens, typically
    ///         the visible page.
    /// @dev    Tolerant of non-conforming tokens: a token whose call reverts
    ///         or returns non-standard data yields an empty string for that
    ///         field.
    /// @param  tokens Token addresses to query.
    /// @return symbols Each token's symbol, or "" on failure.
    /// @return names Each token's name, or "" on failure.
    function meta(address[] calldata tokens)
        external
        view
        returns (string[] memory symbols, string[] memory names)
    {
        symbols = new string[](tokens.length);
        names = new string[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            symbols[i] = _str(tokens[i], 0x95d89b41); // symbol()
            names[i] = _str(tokens[i], 0x06fdde03); // name()
        }
    }

    /// @notice Returns everything a single project's passport or badge
    ///         display needs in one call, so a serverless OG-image or badge
    ///         endpoint requires only one `eth_call`.
    /// @param  token Project token address.
    /// @return symbol Token symbol.
    /// @return toll Cumulative toll contribution, from the furnace.
    /// @return flags Tool bitmap for the token.
    /// @return burned Token balance held at the dead address.
    function passport(address token)
        external
        view
        returns (string memory symbol, uint256 toll, uint8 flags, uint256 burned)
    {
        symbol = _str(token, 0x95d89b41); // symbol()
        toll = furnace.projectContribution(token);
        flags = _flagsOf(token);
        burned = _balanceOf(token, 0x000000000000000000000000000000000000dEaD);
    }

    /// @notice Reports whether a token's Router and DCA Treasury are armed.
    /// @dev    Both tools refuse to run until their configuration is frozen:
    ///         `processFees` and `executeDca` open with
    ///         `require(configurationLocked)` and `require(strategyLocked)`
    ///         respectively. A setup that stops after the configure step
    ///         therefore leaves a tool that exists, accrues fees, and never
    ///         acts, without reverting or otherwise warning the creator, who
    ///         can believe their strategy is live indefinitely without
    ///         checking the burn.
    ///
    ///         Also returns the tool addresses, so a UI can offer a
    ///         one-click fix without a second lookup. Fees are not lost
    ///         while a tool is unarmed: locking later processes whatever has
    ///         accumulated.
    ///
    ///         The Burner has no equivalent gate; it is active from
    ///         creation.
    /// @param  token Project token address.
    /// @return router Router address for the token, or the zero address if none.
    /// @return routerArmed True if the router's configuration is locked.
    /// @return dca DCA treasury address for the token, or the zero address if none.
    /// @return dcaArmed True if the DCA treasury's strategy is locked.
    function toolReadiness(address token)
        external
        view
        returns (address router, bool routerArmed, address dca, bool dcaArmed)
    {
        IRouterForgeLens rf = IRouterForgeLens(deployer.routerForge());
        IRouterForgeLens lff = IRouterForgeLens(deployer.liquidityForgeFactory());
        uint256 nr = rf.routersCount();
        for (uint256 i; i < nr; ++i) {
            address r = rf.allRouters(i);
            if (_tokenOf(r) != token) continue;
            router = r;
            try ILockableLens(r).configurationLocked() returns (bool v) { routerArmed = v; } catch {}
            break;
        }
        IUniversalLens uf = IUniversalLens(deployer.universalForge());
        uint256 nd = uf.dcaTreasuriesCount();
        for (uint256 i; i < nd; ++i) {
            address d = uf.allDcaTreasuries(i);
            if (_tokenOf(d) != token) continue;
            dca = d;
            try ILockableDcaLens(d).strategyLocked() returns (bool v) { dcaArmed = v; } catch {}
            break;
        }
    }

    /// @notice Returns the four tool contract addresses a token runs, in one
    ///         call, so a management UI can read each tool's live state and
    ///         act on it without scanning the registries itself.
    /// @dev    Performs the same scan as the tool bitmap, returning
    ///         addresses instead of flags.
    /// @param  token Project token address.
    /// @return burner Universal burner address (the pad or plug-in burn tool), or the zero address if none.
    /// @return router Router address, or the zero address if none.
    /// @return liquidity Liquidity forge address, or the zero address if none.
    /// @return dca DCA treasury address, or the zero address if none.
    function toolsForToken(address token)
        external
        view
        returns (address burner, address router, address liquidity, address dca)
    {
        IUniversalLens uf = IUniversalLens(deployer.universalForge());
        uint256 nub = uf.universalBurnersCount();
        for (uint256 i; i < nub; ++i) {
            address b = uf.allUniversalBurners(i);
            if (_tokenOf(b) == token) { burner = b; break; }
        }
        uint256 nd = uf.dcaTreasuriesCount();
        for (uint256 i; i < nd; ++i) {
            address d = uf.allDcaTreasuries(i);
            if (_tokenOf(d) == token) { dca = d; break; }
        }
        IRouterForgeLens rf = IRouterForgeLens(deployer.routerForge());
        uint256 nr = rf.routersCount();
        for (uint256 i; i < nr; ++i) {
            address r = rf.allRouters(i);
            if (_tokenOf(r) == token) { router = r; break; }
        }
        IRouterForgeLens lff = IRouterForgeLens(deployer.liquidityForgeFactory());
        uint256 nl = lff.liquidityForgesCount();
        for (uint256 i; i < nl; ++i) {
            address l = lff.allLiquidityForges(i);
            if (_tokenOf(l) == token) { liquidity = l; break; }
        }
    }

    /// @notice Returns the tools ready to fire, over a bounded window of the
    ///         flat tool index, collapsing a keeper's scan into one call per
    ///         page.
    /// @dev    Without this function a scan costs two calls per tool
    ///         (enumerate, then `canProcess`/`canTrigger`), so its cost grows
    ///         linearly with the number of tools connected. With it a full
    ///         sweep costs `total / limit` calls, whatever that number is.
    ///
    ///         Flags use the BURN/SPLIT/LIQUIDITY/DCA constants so the
    ///         caller knows which trigger to send. A tool whose readiness
    ///         probe reverts is treated as not ready. Burners answer
    ///         `canTrigger()`; all other tools answer `canProcess()`; both
    ///         return `ready` as their first return value.
    /// @param  offset Start index into the flat tool enumeration.
    /// @param  limit  Maximum number of entries to scan.
    /// @return ready Addresses of tools currently ready to fire.
    /// @return readyFlags Category flag for each ready tool.
    /// @return total Total number of tools across all registries.
    function readyTools(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory ready, uint8[] memory readyFlags, uint256 total)
    {
        total = _totalTools();
        if (offset >= total || limit == 0) return (new address[](0), new uint8[](0), total);
        uint256 end = offset + limit;
        if (end > total) end = total;

        address[] memory tmpA = new address[](end - offset);
        uint8[] memory tmpF = new uint8[](end - offset);
        uint256 n;
        for (uint256 k = offset; k < end; ++k) {
            (address tool, uint8 flag) = _toolAt(k);
            bytes4 sel = flag == BURN ? bytes4(0x87729fc8) : bytes4(0x27e67603); // canTrigger() : canProcess()
            (bool ok, bytes memory d) = tool.staticcall(abi.encodeWithSelector(sel));
            if (ok && d.length >= 32 && abi.decode(d, (bool))) {
                tmpA[n] = tool;
                tmpF[n] = flag;
                ++n;
            }
        }
        ready = new address[](n);
        readyFlags = new uint8[](n);
        for (uint256 i; i < n; ++i) { ready[i] = tmpA[i]; readyFlags[i] = tmpF[i]; }
    }

    /// @notice The live split of a token's Revenue Router (Tool 2), if it has
    ///         one, so the creator panel can show the actual allocation bar
    ///         instead of a generic label. Returns empty arrays if the token
    ///         has no router, or one that is not yet configured.
    /// @dev    kinds: 0 BUYBACK_BURN, 1 TREASURY, 2 REWARDS, 3 LIQUIDITY.
    /// @param  token Project token address.
    /// @return kinds Allocation kind for each configured slice.
    /// @return bps Allocation size for each slice, in basis points.
    function routerAllocations(address token)
        external
        view
        returns (uint8[] memory kinds, uint16[] memory bps)
    {
        IRouterForgeLens rf = IRouterForgeLens(deployer.routerForge());
        IRouterForgeLens lff = IRouterForgeLens(deployer.liquidityForgeFactory());
        uint256 nr = rf.routersCount();
        for (uint256 i; i < nr; ++i) {
            address r = rf.allRouters(i);
            if (_tokenOf(r) != token) continue;
            uint256 n = IRouterLens(r).allocationsCount();
            kinds = new uint8[](n);
            bps = new uint16[](n);
            for (uint256 j; j < n; ++j) {
                (uint8 k, uint16 b,) = IRouterLens(r).allocations(j);
                kinds[j] = k;
                bps[j] = b;
            }
            return (kinds, bps);
        }
    }

    // --- internals ---

    function _tokenOf(address tool) private view returns (address) {
        return IToolLens(tool).projectToken();
    }

    /// @dev Returns the tool bitmap for a single token by scanning the
    ///      enumerable arrays.
    function _flagsOf(address token) private view returns (uint8 f) {
        uint256 nf = deployer.forgesCount();
        for (uint256 i; i < nf; ++i) {
            IForgeLens forge = IForgeLens(deployer.allForges(i));
            uint256 nt = forge.toolsCount();
            for (uint256 j; j < nt; ++j) if (_tokenOf(forge.allTools(j)) == token) f |= BURN;
        }
        IUniversalLens uf = IUniversalLens(deployer.universalForge());
        uint256 nub = uf.universalBurnersCount();
        for (uint256 i; i < nub; ++i) if (_tokenOf(uf.allUniversalBurners(i)) == token) f |= BURN;
        uint256 nd = uf.dcaTreasuriesCount();
        for (uint256 i; i < nd; ++i) if (_tokenOf(uf.allDcaTreasuries(i)) == token) f |= DCA;
        IRouterForgeLens rf = IRouterForgeLens(deployer.routerForge());
        IRouterForgeLens lff = IRouterForgeLens(deployer.liquidityForgeFactory());
        uint256 nr = rf.routersCount();
        for (uint256 i; i < nr; ++i) if (_tokenOf(rf.allRouters(i)) == token) f |= SPLIT;
        uint256 nl = lff.liquidityForgesCount();
        for (uint256 i; i < nl; ++i) if (_tokenOf(lff.allLiquidityForges(i)) == token) f |= LIQUIDITY;
    }

    function _balanceOf(address token, address who) private view returns (uint256) {
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSelector(0x70a08231, who)); // balanceOf
        if (ok && d.length >= 32) return abi.decode(d, (uint256));
        return 0;
    }

    function _mark(address[] memory toks, uint8[] memory fl, uint256 n, address t, uint8 flag)
        private
        pure
        returns (uint256)
    {
        for (uint256 i; i < n; ++i) {
            if (toks[i] == t) {
                fl[i] |= flag;
                return n;
            }
        }
        toks[n] = t;
        fl[n] = flag;
        return n + 1;
    }

    function _totalTools() private view returns (uint256 total) {
        uint256 nf = deployer.forgesCount();
        for (uint256 i; i < nf; ++i) {
            total += IForgeLens(deployer.allForges(i)).toolsCount();
        }
        IUniversalLens uf = IUniversalLens(deployer.universalForge());
        total += uf.universalBurnersCount() + uf.dcaTreasuriesCount();
        IRouterForgeLens rf = IRouterForgeLens(deployer.routerForge());
        IRouterForgeLens lff = IRouterForgeLens(deployer.liquidityForgeFactory());
        total += rf.routersCount() + lff.liquidityForgesCount();
    }

    function _str(address token, bytes4 sel) private view returns (string memory) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSelector(sel));
        if (ok && data.length >= 64) return abi.decode(data, (string));
        return "";
    }
}
