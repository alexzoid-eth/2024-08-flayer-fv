// Ensures that any non-view function changes storage
rule noOpFunctionDetection(env e, method f, calldataarg args) 
    filtered { f -> !f.isView && !f.isPure } 
{
    // Snapshot contract storage before calling the function
    storage before = lastStorage;

    // Call the function with arbitrary arguments
    f(e, args);

    // Snapshot storage again after the function call
    storage after = lastStorage;

    // For at least one run, the storage must change
    satisfy(before[currentContract] != after[currentContract]);
}
