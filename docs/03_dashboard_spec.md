# Giai đoạn 5: Dashboard

Dashboard web thay cho Power BI (máy phát triển chưa cài Power BI Desktop). Nó đọc star schema trong
`TelcoDW.mart` và không tự tính chỉ số: mọi phép tính nằm trong SQL.

**Chạy:** `python -m src.dashboard.app` rồi mở <http://127.0.0.1:5000>.

## 1. Ba trang

| Trang | Cho ai | Bố cục |
|---|---|---|
| **Khám phá churn** | Lãnh đạo, Marketing, CSKH | Vừa 1 màn hình (khung tham chiếu: 1 trang A4 ngang) |
| **What-if Scenario** | Lãnh đạo, Marketing | Vừa 1 màn hình |
| **Data Quality** | Đội dữ liệu, người cần tra cứu | Trang tra cứu, được phép dài; phần đầu vẫn tóm tắt gọn |

Ba trang báo cáo tĩnh cũ (Overview, Drivers, Risk) được gộp vào trang Khám phá: mỗi trang tĩnh trước đây
chỉ là một tổ hợp bộ lọc cố định, nay trở thành một "góc nhìn có sẵn" hoặc một cú bấm.

**Nguyên tắc bố cục cho hai trang chính:** 1 câu kết luận, 4 KPI, tối đa 2 khối nội dung. Chi tiết chỉ mở khi cần
(popover, drawer), không bắt người xem cuộn trang. Kiểm tra bằng ảnh chụp khung 1440×900: chiều cao trang
bằng đúng chiều cao cửa sổ.

## 2. Trang Khám phá

Bố cục kiểu trang báo cáo Power BI: một lưới nhiều hình nhỏ, ít chữ, vừa một màn hình (khung 16:9 / A4 ngang).

```
┌ Góc nhìn ▾ │ Hợp đồng ▾ │ Internet ▾ │ Gắn bó ▾ │ Dịch vụ kèm ▾ │ Thanh toán ▾ │ Hỗ trợ KT ▾ │ Khác ▾ │      Xoá lọc ┐
│ 1 dòng tóm tắt tự sinh                                                                                        │
├ KPI+sparkline: Khách │ Đã rời đi 24 th │ Rời đi tháng gần nhất │ MRR tháng gần nhất │ MRR dự kiến mất/tháng ┤
├ Tỷ lệ rời đi theo tháng (đường)      │ MRR theo tháng (cột)          │ Yếu tố tác động mạnh nhất       ┤
├ Rời đi theo hợp đồng │ theo gắn bó   │ Donut: khách rời đi đến từ đâu │ (Đang lọc ✕ · ô ▲/▼ · cuộn dọc) ┘
```

- **Lọc:** thanh lọc một hàng, không thanh cuộn (6 yếu tố chính + "Khác"). Cùng một yếu tố chọn nhiều giá trị là HOẶC, khác yếu tố là VÀ. Bảng chọn hiện sẵn số khách và tỷ lệ rời đi của từng lựa chọn. Bộ lọc lưu trên URL.
- **Hai loại câu hỏi:** các biểu đồ cột trả lời *nhóm nào rời đi với tỷ lệ cao*; donut trả lời *khách rời đi đến từ đâu* (cơ cấu). Ví dụ Fiber rời đi 41,9% nhưng chiếm 69% tổng số khách rời đi, vì vừa rời đi nhiều vừa đông khách.
- **Lọc chéo như Power BI:** bấm một cột (hợp đồng, gắn bó) hoặc một lát donut (internet) để lọc theo giá trị đó, bấm lại để bỏ. Cột đang chọn tô đậm, cột khác làm mờ; đường đứt nét là mức rời đi chung của công ty.
- **Bỏ chọn ở mọi nơi:** ✕ trên thanh lọc, bỏ tick trong bảng chọn, bấm lại cột đậm, hoặc ✕ ở hàng "Đang lọc" trong panel.
- **5 thẻ KPI có sparkline 24 tháng** và so sánh với tháng trước (đỏ là xấu đi, xanh là tốt lên).
- **Panel yếu tố tác động mạnh nhất:** mọi yếu tố xếp từ mạnh đến yếu, cuộn dọc trong panel. Mỗi yếu tố có ô ▲ nhánh rời đi nhiều nhất và ô ▼ ít nhất, bấm để lọc. Không xếp hạng nhánh dưới 30 khách (nhóm quá nhỏ thì hạ xuống 5 khách và gắn nhãn "Mẫu nhỏ"); bỏ "Không dùng internet" ở các yếu tố phụ thuộc internet.
- **Chi tiết khi cần:** "Xem danh sách ›" trong thẻ Khách mở danh sách khách đang hoạt động (tìm kiếm, sắp xếp, xuất CSV); "Xem mọi nhánh của từng yếu tố" mở đủ 13 yếu tố.

## 3. Mỗi hình trả lời một câu hỏi

Mỗi hình có dòng 1 là **câu hỏi kinh doanh**, dòng 2 là **câu trả lời** tính từ dữ liệu đang lọc (đổi theo bộ lọc).

| # | Câu hỏi | Chỉ số | Nguồn (result set của `mart.usp_explore`) | Hình | Câu trả lời tự sinh |
|---|---|---|---|---|---|
| 1 | Tỷ lệ rời đi đang tăng hay giảm? | khách rời đi / khách trong tháng | 3 · xu hướng theo tháng | Đường, so với toàn công ty hoặc chỉ tiêu | Đỉnh, tháng gần nhất so với bình quân |
| 2 | Doanh thu định kỳ có đạt chỉ tiêu không? (khi lọc: nhóm đóng góp bao nhiêu?) | tổng cước tháng, chỉ tiêu Finance | 3 · xu hướng theo tháng | Cột + đường chỉ tiêu | Số tháng đạt; chênh lệch tháng gần nhất (hoặc tỷ trọng MRR) |
| 3 | Loại hợp đồng nào dễ rời đi nhất? | tỷ lệ rời đi 24 tháng theo hợp đồng | 2 · thống kê theo yếu tố | Thanh ngang, lọc chéo | Nhánh cao nhất gấp mấy lần nhánh thấp nhất |
| 4 | Khách thường rời đi ở giai đoạn nào? | tỷ lệ rời đi theo nhóm gắn bó | 2 · thống kê theo yếu tố | Cột, lọc chéo | Giai đoạn rời đi nhiều nhất và ít nhất |
| 5 | Khách rời đi đến từ đâu? | tỷ trọng khách rời đi theo loại internet | 2 · thống kê theo yếu tố | Donut, lọc chéo | Phần lớn nhất chiếm bao nhiêu % |
| 6 | Yếu tố nào tạo khác biệt lớn nhất? | chênh lệch tỷ lệ rời đi giữa nhánh cao và thấp nhất, 13 yếu tố | 2 · thống kê theo yếu tố | Danh sách xếp hạng | Yếu tố đứng đầu và hai nhánh của nó |
| KPI | Nhóm lớn cỡ nào, rời đi bao nhiêu, mất bao nhiêu tiền? | khách, tỷ lệ rời đi, MRR, MRR dự kiến mất | 1 · KPI + 3 · xu hướng | Thẻ số + sparkline | So với tháng trước / mức chung |

**Cách tổ chức truy vấn:** gom theo **mức chi tiết (grain)** của dữ liệu, không tách theo từng hình.
Câu hỏi 1, 2 và sparkline KPI cùng cần số liệu theo tháng, nên dùng chung một result set. Câu hỏi 3–6 cùng cần
"tỷ lệ rời đi của từng nhánh trong ngữ cảnh lọc", nên dùng chung một result set (một lần quét bảng cầu nối).
Nếu viết mỗi hình một truy vấn thì sẽ thành 6–8 lượt gọi (N+1) và quét bảng fact nhiều lần cho cùng một kết quả.

**Phân công:** định nghĩa chỉ số (tử số, mẫu số, cửa sổ thời gian) nằm trong SQL, là nguồn sự thật duy nhất.
Giao diện chỉ chọn số cần nói (lớn nhất, nhỏ nhất, tháng gần nhất) và diễn đạt thành câu.

## 4. Hiệu năng truy vấn

Mỗi lần đổi bộ lọc chỉ gọi **1 stored procedure, 1 round-trip** (`mart.usp_explore`), không có N+1:

| Kỹ thuật | Vì sao |
|---|---|
| Stored procedure tĩnh, bộ lọc truyền dạng JSON (`OPENJSON`) | Kế hoạch thực thi biên dịch một lần rồi tái sử dụng; không có SQL động nên không có đường cho SQL injection |
| Một lượt gọi trả nhiều result set (KPI, tác động từng yếu tố, xu hướng...) | Một round-trip thay vì nhiều |
| Nhóm đang chọn và toàn công ty tính trong cùng một lần quét (`SUM(CASE WHEN sel = 1 ...)`) | Không chạy truy vấn thứ hai cho "toàn công ty" |
| Bảng cầu nối `mart.customer_factor` (khách × yếu tố × giá trị) | Bộ lọc tuỳ ý chỉ là một phép join với bảng bộ lọc; tác động của 13 yếu tố tính trong một lần gom nhóm thay vì 13 truy vấn |
| `mart.customer_snapshot` (bản vật lý hoá của view hồ sơ khách) | View phải gom 228 nghìn dòng fact mỗi lần đọc (~2-3 giây); bảng snapshot nạp một lần mỗi batch ETL |
| Columnstore index trên `fact_billing`, `fact_tickets`, `customer_factor` | Batch mode: bước tính tác động giảm từ 260 ms xuống 35 ms |
| Cache phía server theo batch ETL + bộ lọc | Bộ lọc đã từng xem trả về ngay (~2 ms); chạy lại ETL là cache tự làm mới |
| Gộp các cú bấm liên tiếp (120 ms) và huỷ request cũ (`AbortController`) | Bấm nhanh nhiều lựa chọn không tạo hàng loạt request |

Số đo trên máy phát triển: ~600 ms với SQL động lúc đầu, **~290 ms** sau khi tối ưu (lần đầu một bộ lọc),
**~2 ms** khi trúng cache. Đo từng câu lệnh bằng `sys.dm_exec_query_stats`.

**Kiểm chứng tính đúng:** bộ lọc "hợp đồng tháng + Fiber + trả tay" ra 1.508 khách, churn 5,46%/tháng,
MRR $53.883, MRR dự kiến mất $2.941, khớp phân khúc rủi ro trong
[06_risk_segments.sql](../sql/analysis/06_risk_segments.sql). Không lọc thì số theo tháng khớp
`mart.v_kpi_monthly` (ví dụ 2025-04: 4.814 khách, 149 rời đi).

## 5. Quy tắc trình bày

- Nhãn tiếng Việt cho người không chuyên ("Theo tháng", "Trả tay", "Đã rời đi (24 tháng)").
- Màu: xanh là nhóm đang chọn, xám là toàn công ty, nét đứt là chỉ tiêu. Xanh lá/đỏ chỉ dùng cho nhánh rời đi ít/nhiều nhất và luôn có số đi kèm.
- Không dùng biểu đồ hai trục tung; mọi biểu đồ có tooltip; chế độ sáng/tối có bộ màu riêng; dưới 900 px bố cục chuyển thành một cột.
