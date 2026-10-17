#include "lowlevel.h"
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <IOKit/IOKitLib.h>

void wakeDisplay(void)
{
    static IOPMAssertionID assertionID;
    // Each declare without a matching release leaks a power assertion;
    // wake retries arrive 1s apart, so drop the previous one first.
    if (assertionID) {
        IOPMAssertionRelease(assertionID);
        assertionID = 0;
    }
    IOPMAssertionDeclareUserActivity(CFSTR("BLEUnlock"), kIOPMUserActiveLocal, &assertionID);
}

void sleepDisplay(void)
{
    io_registry_entry_t reg = IORegistryEntryFromPath(kIOMasterPortDefault, "IOService:/IOResources/IODisplayWrangler");
    if (reg) {
        IORegistryEntrySetCFProperty(reg, CFSTR("IORequestIdle"), kCFBooleanTrue);
        IOObjectRelease(reg);
    }
}
