# iBoot Stage 0 AVPBooter Patching

Source: https://gist.github.com/steven-michaud/fda019a4ae2df3a9295409053a53a65c

## Key Method

1. Search for "0x4447" ('DG' of DGST) - appears twice in image4_validate_property_callback
2. Find the MOV instruction before function return that moves a value into x0
3. Change it to: mov x0, #0x0 (return 0 = success)
4. Result should be exactly one 4-byte change

## The function validates IMG4 digests during boot.

## Patching it to return 0 bypasses all signature verification.
