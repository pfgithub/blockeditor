#include <3ds.h>

typedef int8_t i8;

typedef struct zigpart_Instance zigpart_Instance;

zigpart_Instance* zigpart_create();
void zigpart_destroy(zigpart_Instance* instance);

void zigpart_tick(zigpart_Instance* instance, int keys_h, u8* tex_buf);
i8* zigpart_getRenderOffsets(zigpart_Instance* instance);
u32 zigpart_getBgColor(zigpart_Instance* instance);

extern u16 swizzle_data_u16[65536];