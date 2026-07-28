/*
 * Golden-vector capture harness for the librtlsdr R820T2 tuner driver.
 *
 * Compiles together with the *unmodified* reference file src/tuner_r82xx.c
 * and provides stub implementations of the rtl-side callbacks that file
 * references, so we can drive r82xx_init / r82xx_set_freq / r82xx_set_gain
 * without libusb or real hardware and log every I2C register write.
 *
 * Output: JSON on stdout in the schema required by Task 13.
 */

#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>

#include "tuner_r82xx.h"

/* ------------------------------------------------------------------ */
/* Write log                                                          */
/* ------------------------------------------------------------------ */

typedef struct { int reg; int value; } write_entry;

#define MAX_WRITES 4096
static write_entry g_writes[MAX_WRITES];
static int         g_write_count = 0;
static int         g_capture = 0;   /* 1 = record writes, 0 = ignore (used during init) */

static void log_reset(void) { g_write_count = 0; }

/* ------------------------------------------------------------------ */
/* Deterministic chip-read model                                      */
/*                                                                    */
/* r82xx_read() bit-reverses every byte it receives from the i2c read */
/* callback (see r82xx_bitrev in tuner_r82xx.c).  We therefore return  */
/* bitrev(desired) so that the driver observes `desired`.             */
/*                                                                    */
/* desired register-0 read image (post bit-reverse):                  */
/*   reg2 = 0x40  -> PLL "locked" bit set, so r82xx_set_pll() reports  */
/*                   has_lock = 1 and emits the full write sequence    */
/*                   (incl. the final 0x1a autotune-8kHz write).       */
/*   reg4 = 0x20  -> vco_fine_tune = (0x20 & 0x30) >> 4 = 2, equal to  */
/*                   vco_power_ref (=2 for R820T), so div_num is NOT    */
/*                   nudged  ->  divider comes purely from the         */
/*                   documented mix_div search.  Also (0x20 & 0x0f)=0  */
/*                   so the filter-cal code in r82xx_set_tv_standard()  */
/*                   is 0.                                             */
/*   all other bytes = 0.                                             */
/* ------------------------------------------------------------------ */

static uint8_t bitrev(uint8_t byte)
{
    const uint8_t lut[16] = { 0x0, 0x8, 0x4, 0xc, 0x2, 0xa, 0x6, 0xe,
                              0x1, 0x9, 0x5, 0xd, 0x3, 0xb, 0x7, 0xf };
    return (lut[byte & 0xf] << 4) | lut[byte >> 4];
}

static uint8_t desired_read_image(int reg)
{
    if (reg == 2) return 0x40;
    if (reg == 4) return 0x20;
    return 0x00;
}

/* ------------------------------------------------------------------ */
/* rtl-side callback stubs referenced by tuner_r82xx.c                */
/* ------------------------------------------------------------------ */

int rtlsdr_i2c_write_fn(void *dev, uint8_t addr, uint8_t *buf, int len)
{
    (void)dev; (void)addr;
    /* buf[0] = start register, buf[1..len-1] = consecutive register values */
    if (g_capture) {
        int k;
        for (k = 1; k < len; ++k) {
            if (g_write_count < MAX_WRITES) {
                g_writes[g_write_count].reg   = buf[0] + (k - 1);
                g_writes[g_write_count].value = buf[k];
                g_write_count++;
            }
        }
    }
    return len; /* driver expects rc == size+1 == len */
}

int rtlsdr_i2c_read_fn(void *dev, uint8_t addr, uint8_t *buf, int len)
{
    (void)dev; (void)addr;
    /* read starts at register 0; buf[i] corresponds to register i.
     * Return bitrev(desired) so the driver's bit-reverse yields `desired`. */
    int i;
    for (i = 0; i < len; ++i)
        buf[i] = bitrev(desired_read_image(i));
    return len;
}

/* Declared in tuner_r82xx.h; used by set_freq64 / set_if_mode. Not a v4. */
int rtlsdr_check_dongle_model(void *dev, char *manufact_check, char *product_check)
{
    (void)dev; (void)manufact_check; (void)product_check;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Fixture driving                                                    */
/* ------------------------------------------------------------------ */

static struct r82xx_config g_cfg;
static struct r82xx_priv   g_priv;

static void config_init(void)
{
    memset(&g_cfg, 0, sizeof(g_cfg));
    g_cfg.i2c_addr        = 0x34;        /* R820T_I2C_ADDR */
    g_cfg.rafael_chip     = CHIP_R820T;
    g_cfg.xtal            = 28800000;    /* 28.8 MHz */
    g_cfg.max_i2c_msg_len = 8;           /* per librtlsdr.c */
    g_cfg.use_predetect   = 0;
    g_cfg.harmonic        = 0;
    g_cfg.vco_curr_min    = 0xff;        /* default */
    g_cfg.vco_curr_max    = 0xff;        /* default */
    g_cfg.vco_algo        = 0x00;        /* default divider algorithm */
    g_cfg.verbose         = 0;
}

/* Fresh, fully-initialised tuner so every captured vector is independent. */
static void fresh_init(void)
{
    memset(&g_priv, 0, sizeof(g_priv));
    g_priv.cfg = &g_cfg;
    g_capture = 0;          /* do not record init writes */
    log_reset();
    r82xx_init(&g_priv);
    log_reset();
    g_capture = 1;          /* record the next call */
}

static void emit_writes(void)
{
    int i;
    printf("      \"writes\": [");
    for (i = 0; i < g_write_count; ++i) {
        printf("%s{ \"reg\": %d, \"value\": %d }",
               (i == 0 ? "\n        " : ",\n        "),
               g_writes[i].reg, g_writes[i].value);
    }
    printf("%s]\n", (g_write_count ? "\n      " : ""));
}

int main(void)
{
    const uint32_t freqs[] = {
        100000000u, 173225000u, 433920000u, 868000000u, 1090000000u
    };
    const int gains[] = { 0, 166, 328 };
    int i;

    config_init();

    printf("{\n");

    /* ---- setFreq ---- */
    printf("  \"setFreq\": [\n");
    for (i = 0; i < (int)(sizeof(freqs)/sizeof(freqs[0])); ++i) {
        fresh_init();
        r82xx_set_freq(&g_priv, freqs[i]);
        g_capture = 0;
        printf("    {\n");
        printf("      \"hz\": %u,\n", freqs[i]);
        emit_writes();
        printf("    }%s\n", (i + 1 < (int)(sizeof(freqs)/sizeof(freqs[0])) ? "," : ""));
    }
    printf("  ],\n");

    /* ---- setGain ---- */
    printf("  \"setGain\": [\n");
    for (i = 0; i < (int)(sizeof(gains)/sizeof(gains[0])); ++i) {
        int rtl_vga_control = 0;
        fresh_init();
        /* manual gain: mirrors r820t_set_gain() in librtlsdr.c */
        r82xx_set_gain(&g_priv, 1, gains[i], 0, 0, 0, 0, &rtl_vga_control);
        g_capture = 0;
        printf("    {\n");
        printf("      \"tenthsDb\": %d,\n", gains[i]);
        printf("      \"mode\": \"manual\",\n");
        emit_writes();
        printf("    },\n");
    }
    /* automatic gain: mirrors r820t_set_gain_mode(dev, 0) in librtlsdr.c */
    {
        int rtl_vga_control = 0;
        fresh_init();
        r82xx_set_gain(&g_priv, 0, 0, 0, 0, 0, 0, &rtl_vga_control);
        g_capture = 0;
        printf("    {\n");
        printf("      \"mode\": \"auto\",\n");
        emit_writes();
        printf("    }\n");
    }
    printf("  ]\n");

    printf("}\n");
    return 0;
}
