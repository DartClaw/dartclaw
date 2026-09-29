/// A size target fails only when its measured line count reaches 110%.
bool locExceedsTarget(int measured, int target) => measured * 10 >= target * 11;
