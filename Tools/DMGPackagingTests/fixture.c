#include <stdio.h>

#ifdef DMG_LIBRARY
int dmg_fixture(void) {
  return 0;
}
#else
#ifdef DMG_LINK_FIXTURE
extern int dmg_fixture(void);
#endif
int main(void) {
  puts("Synthetic ARM64 DMG packaging fixture; not ChengYingPlayer.");
#ifdef DMG_LINK_FIXTURE
  return dmg_fixture();
#else
  return 0;
#endif
}
#endif
