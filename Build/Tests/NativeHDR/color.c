#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "avfoundation_color_math.h"

static void near(double got, double expected, double eps) {
    if (fabs(got - expected) > eps) { fprintf(stderr, "got %.12g expected %.12g ± %.3g\n", got, expected, eps); assert(0); }
}
static struct avf_overlay_color setup(enum avf_transfer trc) {
    return (struct avf_overlay_color){.transfer=trc, .kr=.2627, .kb=.0593, .white_nits=203,
        .rgb_matrix={{.627403896,.329283038,.043313066},{.069097289,.919540395,.011362316},{.016391439,.088013308,.895595253}}};
}
int main(void) {
    // Independent BT.2100 reference anchors, not just forward/inverse agreement.
    double pq[3]={100,203,1000}; avf_from_nits(AVF_PQ,pq,.2627,.0593);
    near(pq[0], .5080784215, 1e-9); near(pq[1],.5806888810,1e-9); near(pq[2],.7518270962,1e-9);
    double hlg[3]={.75,.75,.75}; avf_to_nits(AVF_HLG,hlg,.2627,.0593);
    near(hlg[0],203.1521459,1e-5);
    for (int trc=AVF_SRGB;trc<=AVF_LINEAR;trc++) {
        double rgb[3]={.13,.42,.79}, original[3];memcpy(original,rgb,sizeof(rgb));
        avf_to_nits(trc,rgb,.2627,.0593);avf_from_nits(trc,rgb,.2627,.0593);
        for (int c=0;c<3;c++) near(rgb[c],original[c],1e-7);
    }
    uint8_t white[4]={255,255,255,255}, red[4]={0,0,255,255}, half[4]={128,128,128,128}, clear[4]={0};
    for (int trc=AVF_PQ;trc<=AVF_HLG;trc++) {
        struct avf_overlay_color color=setup(trc);
        double yuv[3]={0,0,0};avf_blend_pixel(&color,white,yuv);
        double rgb[3]={yuv[0],yuv[0],yuv[0]};avf_to_nits(trc,rgb,color.kr,color.kb);near(rgb[0],203,1e-5);
        near(yuv[1],0,1e-8);near(yuv[2],0,1e-8);
        color.white_nits=100; yuv[0]=yuv[1]=yuv[2]=0;avf_blend_pixel(&color,white,yuv);
        rgb[0]=rgb[1]=rgb[2]=yuv[0];avf_to_nits(trc,rgb,color.kr,color.kb);near(rgb[0],100,1e-5);
        color.white_nits=203;
        yuv[0]=yuv[1]=yuv[2]=0;avf_blend_pixel(&color,half,yuv);
        rgb[0]=rgb[1]=rgb[2]=yuv[0];avf_to_nits(trc,rgb,color.kr,color.kb);near(rgb[0],203*128.0/255,1e-5);
        // Black translucent background over 1000 nit white must halve display light.
        uint8_t black[4]={0,0,0,128};rgb[0]=rgb[1]=rgb[2]=1000;
        avf_from_nits(trc,rgb,color.kr,color.kb);yuv[0]=rgb[0];yuv[1]=yuv[2]=0;
        avf_blend_pixel(&color,black,yuv);rgb[0]=rgb[1]=rgb[2]=yuv[0];avf_to_nits(trc,rgb,color.kr,color.kb);
        near(rgb[0],1000*127.0/255,1e-4);
        yuv[0]=yuv[1]=yuv[2]=0;avf_blend_pixel(&color,red,yuv);
        rgb[0]=yuv[0]+2*(1-color.kr)*yuv[2];rgb[2]=yuv[0]+2*(1-color.kb)*yuv[1];
        rgb[1]=(yuv[0]-color.kr*rgb[0]-color.kb*rgb[2])/(1-color.kr-color.kb);
        avf_to_nits(trc,rgb,color.kr,color.kb);
        near(rgb[0],203*.627403896,1e-4);near(rgb[1],203*.069097289,1e-4);near(rgb[2],203*.016391439,1e-4);
        // Odd-position red coverage; all other luma stays bit-exact.
        uint8_t cell[4][4]={{0}};memcpy(cell[3],red,4);
        double ys[4]={.1,.2,.3,.4}, uv[2]={.1,-.05}, single[3]={.4,.1,-.05};
        avf_blend_pixel(&color,red,single);assert(avf_blend_chroma_cell(&color,cell,ys,uv,4));
        assert(ys[0]==.1 && ys[1]==.2 && ys[2]==.3);near(ys[3],single[0],1e-15);
        near(uv[0],.1+(single[1]-.1)/4,1e-15);near(uv[1],-.05+(single[2]+.05)/4,1e-15);
        // Empty and clipped edge cells, and superblack outside overlay.
        memset(cell,0,sizeof(cell));double origy[4], origuv[2];memcpy(origy,ys,sizeof(ys));memcpy(origuv,uv,sizeof(uv));
        assert(!avf_blend_chroma_cell(&color,cell,ys,uv,4));assert(!memcmp(origy,ys,sizeof(ys)));assert(!memcmp(origuv,uv,sizeof(uv)));
        double untouched[3]={-.1,.8,-.7}, before[3];memcpy(before,untouched,sizeof(before));avf_blend_pixel(&color,clear,untouched);assert(!memcmp(before,untouched,sizeof(before)));
        memcpy(cell[0],red,4);ys[0]=.4;uv[0]=.1;uv[1]=-.05;
        avf_blend_chroma_cell(&color,cell,ys,uv,1);near(uv[0],single[1],1e-15);
    }
    puts("Native HDR math: PQ/HLG anchors, gamut, reference white, linear alpha, antialiasing, chroma coverage, untouched pixels passed");
}
