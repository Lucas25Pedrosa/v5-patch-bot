// Compatibility wrapper for SDKs where UIViewController exposes
// childViewControllers instead of the modern children property name.
#define children childViewControllers
#include "Tweak.m"
