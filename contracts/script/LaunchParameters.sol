// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Exact launch defaults; owner is supplied by the launch, never inferred.
library LaunchParameters {
    address internal constant INTAKE = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    address internal constant ASSET = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function prefix() internal pure returns (bytes memory) {
        return bytes("{\"parentJobId\":\"");
    }

    function suffix() internal pure returns (bytes memory) {
        return bytes(
            "\",\"objective\":\"Refresh the IMD burn tracker's data and host the site again. Build it with the repository's own build script (package.json), which needs network access: it refreshes the data files in dist/data/ from public sources, or keeps them and notes why in dist/data/imd-refresh-status.json. Change nothing else: the hosted files are dist/ after that build. Decide, do not ask: a question blocks the job.\",\"shape\":\"chain\",\"steps\":[{\"skill\":\"import-site\"},{\"skill\":\"site-content-check\",\"acceptanceCriteria\":[\"only files under dist/data/ differ from the parent version\",\"dist/index.html loads with no console error and shows the data's refresh time from dist/data/imd-refresh-status.json\"]}],\"ipfs\":true,\"github\":true}"
        );
    }

    function template() internal pure returns (bytes memory) {
        return bytes(
            "{\"parentJobId\":\"{{PARENT}}\",\"objective\":\"Refresh the IMD burn tracker's data and host the site again. Build it with the repository's own build script (package.json), which needs network access: it refreshes the data files in dist/data/ from public sources, or keeps them and notes why in dist/data/imd-refresh-status.json. Change nothing else: the hosted files are dist/ after that build. Decide, do not ask: a question blocks the job.\",\"shape\":\"chain\",\"steps\":[{\"skill\":\"import-site\"},{\"skill\":\"site-content-check\",\"acceptanceCriteria\":[\"only files under dist/data/ differ from the parent version\",\"dist/index.html loads with no console error and shows the data's refresh time from dist/data/imd-refresh-status.json\"]}],\"ipfs\":true,\"github\":true}"
        );
    }
}
