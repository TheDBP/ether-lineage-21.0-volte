/* smem_poke: dump, and optionally rewrite one word of, Qualcomm SMEM items from the AP.
 *
 *   insmod smem_poke.ko [ids=134,135,136,137] [maxdump=N]
 *   insmod smem_poke.ko do_poke=1 poke_id=135 poke_off=12 poke_val=0
 *
 * Output goes to dmesg, prefixed "smem_poke:". Items 134..137 are SMEM_ID_VENDOR0/1/2 and
 * SMEM_ID_HW_SW_BUILD_ID (include/soc/qcom/smem.h), the blocks a vendor bootloader fills in
 * for the modem; a modem that caches a pointer into SMEM sees a poke on its next read, so a flag
 * can be tested on a live system before anything is patched. Build with tools/kmod-build.sh;
 * an Android kernel has no /dev/mem and smem debugfs lists only the legacy TOC.
 */
#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/err.h>
#include <soc/qcom/smem.h>

static unsigned int ids[8] = { 134, 135, 136, 137 };
static int nids = 4;
module_param_array(ids, uint, &nids, 0);
static unsigned int poke_id, poke_off, poke_val, do_poke;
module_param(poke_id, uint, 0);
module_param(poke_off, uint, 0);
module_param(poke_val, uint, 0);
module_param(do_poke, uint, 0);
static unsigned int maxdump = 2304;
module_param(maxdump, uint, 0);

static void dump_item(unsigned int id)
{
	unsigned int size = 0;
	void *p = smem_get_entry(id, &size, 0, SMEM_ANY_HOST_FLAG);
	if (IS_ERR_OR_NULL(p)) {
		pr_info("smem_poke: item %u: not found (%ld)\n", id, (long)PTR_ERR(p));
		return;
	}
	pr_info("smem_poke: item %u size %u\n", id, size);
	print_hex_dump(KERN_INFO, "smem_poke: ", DUMP_PREFIX_OFFSET, 16, 1, p,
		       min(size, maxdump), true);
}

static int __init smem_poke_init(void)
{
	int i;
	if (do_poke) {
		unsigned int size = 0;
		void *p = smem_get_entry(poke_id, &size, 0, SMEM_ANY_HOST_FLAG);
		if (IS_ERR_OR_NULL(p) || poke_off + 4 > size) {
			pr_info("smem_poke: poke failed (item %u size %u off %u)\n", poke_id, size, poke_off);
		} else {
			u32 old = *(u32 *)((char *)p + poke_off);
			*(u32 *)((char *)p + poke_off) = poke_val;
			pr_info("smem_poke: poked item %u off %u: 0x%08x -> 0x%08x\n", poke_id, poke_off, old, poke_val);
		}
	}
	for (i = 0; i < nids; i++)
		dump_item(ids[i]);
	return 0;
}
static void __exit smem_poke_exit(void) { }
module_init(smem_poke_init);
module_exit(smem_poke_exit);
MODULE_LICENSE("GPL");
