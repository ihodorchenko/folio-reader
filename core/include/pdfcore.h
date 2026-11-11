/* Folio PDF core — C ABI (CONTRACT.md §1).
 *
 * Сборка: cargo build --release (staticlib + cdylib).
 * Координаты — точки PDF (1/72"), origin top-left, y вниз, с учётом /Rotate.
 * JSON — UTF-8; освобождать pc_free_json. RGBA-буфер — pc_free_buffer.
 */
#ifndef FOLIO_PDFCORE_H
#define FOLIO_PDFCORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct PcDocument PcDocument;

/* Открыть PDF. NULL при ошибке (pc_last_error). Не держит файл открытым
 * дольше загрузки. */
PcDocument *pc_open(const char *path);
void pc_close(PcDocument *doc);

int32_t pc_page_count(const PcDocument *doc);
/* Размер страницы в точках после применения /Rotate. */
double pc_page_width(const PcDocument *doc, int32_t page);
double pc_page_height(const PcDocument *doc, int32_t page);

/* Рендер в BGRA (B,G,R,A), alpha = 255, фон белый, строка 0 — верхняя.
 * scale: 1.0 == 72 dpi. Буфер освобождать pc_free_buffer.
 * Возврат: 0 = ok, < 0 = ошибка (pc_last_error). */
int32_t pc_render_page(const PcDocument *doc,
                       int32_t page,
                       double scale,
                       int32_t *out_w,
                       int32_t *out_h,
                       uint8_t **out_bgra);

/* Heap-allocated UTF-8 JSON, освобождать pc_free_json. NULL при ошибке.
 * pc_page_layout_json/pc_document_structure_json кэшируются на документ. */
char *pc_page_layout_json(const PcDocument *doc, int32_t page);
char *pc_document_structure_json(const PcDocument *doc);
char *pc_search_json(const PcDocument *doc, const char *query);

void pc_free_buffer(void *ptr);
void pc_free_json(char *ptr);

/* thread-local, UTF-8, валиден до следующего вызова на этом потоке. */
const char *pc_last_error(void);
const char *pc_version(void);

#ifdef __cplusplus
}
#endif

#endif /* FOLIO_PDFCORE_H */
