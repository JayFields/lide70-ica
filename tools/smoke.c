#include <stdio.h>
#include "../include/sane/config.h"
#include "../include/sane/sane.h"
SANE_Status sane_canon_lide70_init(SANE_Int*,SANE_Auth_Callback);SANE_Status sane_canon_lide70_get_devices(const SANE_Device***,SANE_Bool);void sane_canon_lide70_exit(void);
#define sane_init sane_canon_lide70_init
#define sane_get_devices sane_canon_lide70_get_devices
#define sane_exit sane_canon_lide70_exit
int main(void){
  SANE_Int v; const SANE_Device **l; SANE_Status s;
  s = sane_init(&v,NULL); printf("sane_init=%d\n",s);
  s = sane_get_devices(&l,SANE_TRUE); printf("sane_get_devices=%d, first=%s\n",s,l&&l[0]?l[0]->name:"(none)");
  sane_exit(); return 0; }
