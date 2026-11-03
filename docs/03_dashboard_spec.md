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

```
┌ Góc nhìn ▾ │ Hợp đồng ▾ │ Internet ▾ │ Gắn bó ▾ │ Dịch vụ kèm ▾ │ Thanh toán ▾ │ Hỗ trợ KT ▾ │ Khác ▾ │ Xoá lọc ┐
├ 1 câu kết luận (tự sinh)                                                                                                  ┤
├ Khách trong nhóm (Xem danh sách ›) │ Đã rời đi (24 tháng) │ MRR hiện tại │ MRR dự kiến mất / tháng                     ┤
├ Tỷ lệ rời đi theo tháng (nhóm vs toàn công ty, hoặc vs chỉ tiêu)   │ Yếu tố tác động mạnh nhất: ô ▲ / ô ▼ bấm để lọc      ┘
```

- **Bộ lọc:** luôn một hàng, không thanh cuộn. 6 yếu tố chính thành nút thả xuống, 7 yếu tố còn lại gom trong "Khác". Nút đang lọc hiện tên giá trị (nhiều giá trị thì hiện "2 lựa chọn"); thiếu chỗ thì chỉ nút đang lọc rút gọn bằng dấu ba chấm, rê chuột để xem đủ. Cùng một yếu tố chọn nhiều giá trị là HOẶC, khác yếu tố là VÀ. Trong bảng chọn, mỗi lựa chọn hiện luôn số khách và tỷ lệ rời đi theo các bộ lọc còn lại, nên chưa bấm đã biết tác động. Bộ lọc lưu trên URL để gửi link.
- **Góc nhìn có sẵn:** Toàn công ty · Nhóm rủi ro cao (hợp đồng tháng, Fiber, trả tay) · Khách năm đầu · Khách Fiber · Không dùng dịch vụ kèm · Hợp đồng dài hạn.
- **Câu kết luận tự sinh:** quy mô nhóm, tỷ lệ rời đi so với mức chung, và yếu tố khác biệt nhất. Nhóm dưới 100 khách có cảnh báo mẫu nhỏ.
- **Biểu đồ:** tỷ lệ rời đi theo tháng, đánh dấu đỉnh và mốc tăng giá Fiber. Không lọc thì so với chỉ tiêu Finance; có lọc thì so với toàn công ty.
- **Yếu tố tác động mạnh nhất:** mỗi yếu tố có hai ô bấm, ▲ nhánh rời đi nhiều nhất (đỏ) và ▼ ít nhất (xanh). Mỗi ô ghi tỷ lệ, số khách, thanh tỷ lệ; rê chuột hiện "＋ Lọc". Số yếu tố hiển thị tự co theo chiều cao màn hình nên không bị cắt và không phải cuộn. Không xếp hạng nhánh dưới 30 khách, và bỏ "Không dùng internet" ở các yếu tố phụ thuộc internet (vì nó chỉ lặp lại yếu tố Loại internet).
- **Chi tiết khi cần:** nút "Xem đủ 13 yếu tố" ở chân panel; "Xem danh sách ›" trong thẻ Khách trong nhóm mở danh sách khách đang hoạt động (tìm kiếm, sắp xếp, xuất CSV).

## 3. Hiệu năng truy vấn

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

## 4. Quy tắc trình bày

- Nhãn tiếng Việt cho người không chuyên ("Theo tháng", "Trả tay", "Đã rời đi (24 tháng)").
- Màu: xanh là nhóm đang chọn, xám là toàn công ty, nét đứt là chỉ tiêu. Xanh lá/đỏ chỉ dùng cho nhánh rời đi ít/nhiều nhất và luôn có số đi kèm.
- Không dùng biểu đồ hai trục tung; mọi biểu đồ có tooltip; chế độ sáng/tối có bộ màu riêng; dưới 900 px bố cục chuyển thành một cột.
