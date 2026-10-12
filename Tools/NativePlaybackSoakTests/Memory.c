#include "Memory.h"
#include <mach/mach.h>

bool native_soak_memory(uint64_t *resident, uint64_t *footprint) {
  struct mach_task_basic_info basic = {0};
  mach_msg_type_number_t basic_count = MACH_TASK_BASIC_INFO_COUNT;
  task_vm_info_data_t vm = {0};
  mach_msg_type_number_t vm_count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&basic,
                &basic_count) != KERN_SUCCESS ||
      task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm,
                &vm_count) != KERN_SUCCESS) return false;
  *resident = basic.resident_size;
  *footprint = vm.phys_footprint;
  return true;
}
