// CURRENT PROBLEMS:
// - [ ] fps drops down to 30 on the emulator when particles in sponge.zig are
//    showing (at ~50% instruction count). this means that we need jit, or
//    to compile the game into the binary directly. our plan is compiling the
//    game in directly because jit seems difficult (wasm has readonly code
//    and you know where all the code is - really helpful. risc v you can
//    jump halfway through an instruction in writable memory.)
// - [ ] blendModeAlpha() is really slow and doesn't even work
//   - we may need to do alpha compositing on the 3ds's gpu
//   - alternatively, we could severely limit alpha-composited rendered images
//   - or we could find a way to do alpha compositing without switching to float
//     - this is probably doable if we widen the integers
//   - or we could remove alpha as an option and only allow cutout
//      - any alpha compositing must be done in layers

#include <citro2d.h>
#include <3ds.h>
#include "zigpart.h"

int byteOffsetToIntOffset(i8 byte_offset) {
	if(byte_offset <= -64) return -1;
	if(byte_offset >= 64) return 1;
	return 0;
}

int main() {
	// cannot be toggled at runtime:
	// https://github.com/devkitPro/libctru/issues/476
	// https://devkitpro.org/viewtopic.php?f=39&t=9098#p16846
	// we'll have to make our own console I guess so we can toggle it
	// - if it's made in the hypervisor cartridge then it can be used for
	//   windows too
	bool dual_screen = false;

	gfxInitDefault();
	gfxSet3D(true);
	C3D_Init(C3D_DEFAULT_CMDBUF_SIZE);
	C2D_Init(C2D_DEFAULT_MAX_OBJECTS);
	C2D_Prepare();
	if(dual_screen) {
		consoleDebugInit(debugDevice_NULL);
	}else{
		consoleInit(GFX_BOTTOM, NULL);
	}

	// Create targets for both eyes on the top screen
	C3D_RenderTarget* left = C2D_CreateScreenTarget(GFX_TOP, GFX_LEFT);
	C3D_RenderTarget* right = C2D_CreateScreenTarget(GFX_TOP, GFX_RIGHT);
	C3D_RenderTarget* bottom = C2D_CreateScreenTarget(GFX_BOTTOM, GFX_LEFT);

    zigpart_Instance* zigpart = zigpart_create();

	printf("Stereoscopic 3D with citro2d\n");

	int w = 256;
	int h = 256;

	printf("linearAlloc()\n");
    u8 *tex_buf = (u8*) linearAlloc(w*h * 4);

	C3D_Tex texture;
	printf("texinit()\n");
	C3D_TexInit(&texture, w, h, GPU_RGBA8);
	printf("texsetfilter()\n");
	C3D_TexSetFilter(&texture, GPU_NEAREST, GPU_NEAREST);
	printf("done.\n");

	Tex3DS_SubTexture subtextures[4];
	C2D_Image c2d_images[4];
	for(int n = 0; n < 4; n++) {
		float nx = n % 2 == 0 ? 0.0f : 0.5f;
		float ny = n / 2 == 0 ? 0.0f : 0.5f;
		subtextures[n] = (Tex3DS_SubTexture){
			.width = w / 2,
			.height = h / 2,
			.left = nx,
			.top = ny,
			.right = nx + 0.5f,
			.bottom = ny + 0.5f,
		};
		c2d_images[n] = (C2D_Image){
			.tex = &texture,
			.subtex = &subtextures[n],
		};
	}

	while (aptMainLoop()) {
		printf("\x1b[H\n\x1b[J\n");
		// Handle user input
		hidScanInput();

		int keys_d = hidKeysDown();
		int keys_h = hidKeysHeld();
		if (keys_d & KEY_START) break;

		float slider = osGet3DSliderState();

		// Print useful information
		printf("3d slider: %.2f        \n", slider);
		// printf("\x1b[1;1H RR: %d | TB: %d | Tex: %d | Subtex: %d\n", (int)render_result, (int)tex_buf, (int)&texture, (int)&subtex);


		zigpart_tick(zigpart, keys_h, tex_buf);
		i8* render_offsets = zigpart_getRenderOffsets(zigpart);
		u32 bg_color_u32 = zigpart_getBgColor(zigpart);

		printf("texupload()\n");
		C3D_TexUpload(&texture, tex_buf);

		u32 bg_color = bg_color_u32;//C2D_Color32(0xFF, 0xFF, 0xFF, 0xFF);

		printf("\x1b[Hgpu: %5.2f%%  cpu: %5.2f%%  buf:%5.2f%%\x1b[K\n", C3D_GetDrawingTime()*6, C3D_GetProcessingTime()*6, C3D_GetCmdBufUsage()*100);

		// Render the scene
		C3D_FrameBegin(C3D_FRAME_SYNCDRAW);

		// Render the left eye's view
		{
			C2D_TargetClear(left, bg_color); // required because it clears the depth buffer which the previous application may have left full
			C2D_SceneBegin(left);

			for(int n = 0; n < 4; n++) {
				int of_x = byteOffsetToIntOffset(render_offsets[n * 2 + 0]);
				int of_y = byteOffsetToIntOffset(render_offsets[n * 2 + 1]);
				int of_3d = (4 - n - 1) * 2 * slider;
				C2D_DrawImageAt(c2d_images[n], of_x + 80 - of_3d * slider, of_y + 0, 0.0f, NULL, 2.0, 2.0);		
			}

			int of_3d_max = (4 - 0 - 1) * 2 * slider;
			C2D_DrawRectSolid(0, 0, 0, 82, 240, bg_color);
			C2D_DrawRectSolid(82, 0, 0, 236, 2, bg_color);
			C2D_DrawRectSolid(316 - of_3d_max, 0, 0, 82 + of_3d_max, 240, bg_color);
			C2D_DrawRectSolid(82, 238, 0, 236, 2, bg_color);
		}

		// Render the right eye's view
		if(slider > 0.0f) {
			C2D_TargetClear(right, bg_color);
			C2D_SceneBegin(right);

			for(int n = 0; n < 4; n++) {
				int of_x = byteOffsetToIntOffset(render_offsets[n * 2 + 0]);
				int of_y = byteOffsetToIntOffset(render_offsets[n * 2 + 1]);
				int of_3d = (4 - n - 1) * 2 * slider;
				C2D_DrawImageAt(c2d_images[n], of_x + 80 + of_3d, of_y + 0, 0.0f, NULL, 2.0, 2.0);		
			}

			int of_3d_max = (4 - 0 - 1) * 2 * slider;
			C2D_DrawRectSolid(0, 0, 0, 82 + of_3d_max, 240, bg_color);
			C2D_DrawRectSolid(82, 0, 0, 236, 2, bg_color);
			C2D_DrawRectSolid(316, 0, 0, 82, 240, bg_color);
			C2D_DrawRectSolid(82, 238, 0, 236, 2, bg_color);
		}
		if(dual_screen) {
			C2D_TargetClear(bottom, bg_color);
			C2D_SceneBegin(bottom);

			for(int n = 0; n < 4; n++) {
				int of_x = byteOffsetToIntOffset(render_offsets[n * 2 + 0]);
				int of_y = byteOffsetToIntOffset(render_offsets[n * 2 + 1]);
				C2D_DrawImageAt(c2d_images[n], of_x + 40, of_y + 0, 0.0f, NULL, 2.0, 2.0);		
			}

			C2D_DrawRectSolid(0, 0, 0, 42, 240, bg_color);
			C2D_DrawRectSolid(42, 0, 0, 236, 2, bg_color);
			C2D_DrawRectSolid(276, 0, 0, 42, 240, bg_color);
			C2D_DrawRectSolid(42, 238, 0, 236, 2, bg_color);
		}

		C3D_FrameEnd(0);
	}

    C3D_TexDelete(&texture);
	linearFree(tex_buf);
    zigpart_destroy(zigpart);
	C2D_Fini();
	C3D_Fini();
	gfxExit();
}

// https://gbatemp.net/threads/citro3d-loading-png-into-c3d_tex.478416/
// https://github.com/devkitPro/citro2d/issues/16