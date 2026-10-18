# HW_12 — приём кадра 320×200 через AXI DMA на MicroBlaze

Система принимает кадр извне (8 бит на такт, в собственном тактовом домене),
упаковывает пиксели в 32-битные слова и через AXI DMA (S2MM) записывает кадр
в `axi4_full_ram`. Приём стартует только после нажатия кнопки, которое
обрабатывает программа MicroBlaze.

## Формат данных

- Кадр в оттенках серого: 1 пиксель = 1 байт.
- 4 пикселя упаковываются в 32-битное слово, little-endian: первый пиксель в `[7:0]`,
  четвёртый в `[31:24]`.
- 320 × 200 = 64 000 байт = **16 000 слов**.
- RAM: `MEM_DEPTH = 16384`, `ADDR_WIDTH = 16` → окно 64 KB (`0x10000–0x1FFFF`).

## axis_frame_reader

| Порт | Домен | Назначение |
|---|---|---|
| `pix_clk`, `pix_data[7:0]`, `pix_valid` | pix_clk | входной поток пикселей |
| `capture_en` | aclk | разрешение захвата (от AXI GPIO, канал 2) |
| `aclk`, `aresetn` | aclk | системный клок и сброс |
| `m_axis_*` (`tdata`, `tkeep`, `tvalid`, `tready`, `tlast`) | aclk | AXI4-Stream master → `DMA.S_AXIS_S2MM` |
| `overflow` | pix_clk | отладка: переполнение FIFO |

Параметр `FRAME_WORDS = 16000`.

Внутри:
1. **2-FF синхронизатор** `capture_en` → `pix_clk` (`ASYNC_REG`).
2. **Упаковка 8 → 32** сдвиговым регистром и 2-битным счётчиком байт. До `capture_en`
   входы игнорируются; после `FRAME_WORDS` слов захват останавливается до следующего
   подъёма `capture_en`.
3. **Асинхронный FIFO** `xpm_fifo_async` (Block RAM, 1024×32, FWFT) для перехода
   `pix_clk` → `aclk` и сглаживания пауз DMA. Его сброс синхронизирован в `pix_clk`.
4. **AXIS-выход**: `tvalid = ~empty`, `rd_en = tvalid & tready`, `tkeep = 4'hF`,
   `tlast` на 16 000-м слове по счётчику в домене `aclk`.

## axi4_full_ram

Простой AXI4 slave. Память вынесена в отдельные `always`-блоки без сброса, поэтому
Vivado выводит Block RAM. Поддерживаются INCR burst и `WSTRB`; чтение синхронное
(1 beat за 2 такта).

## Настройки IP

- **AXI DMA**: Scatter Gather **выключен**, MM2S выключен, S2MM 32 бит,
  Width of Buffer Length Register = 16.
- **AXI GPIO**: dual channel; канал 1 — вход 1 бит (кнопка), канал 2 — выход 1 бит → `capture_en`.
- **SmartConnect**: 2 slave-входа (MicroBlaze и `DMA.M_AXI_S2MM`).
- **Address Editor**: `axi4_full_ram` 64K, назначен и для MicroBlaze, и для `axi_dma_0/Data_S2MM`.

## Программа (`app_component/src/main.c`)

1. Инициализация GPIO и DMA (проверка, что SG выключен).
2. Ожидание кнопки с антидребезгом (20 мс в железе).
3. Взвести S2MM: `XAxiDma_SimpleTransfer(RAM_BASE, 64000 байт)`.
4. Выставить `start` через GPIO2. Порядок важен: если поднять `start` раньше,
   FIFO переполнится.
5. Ждать `XAxiDma_Busy() == 0`, сбросить GPIO2.

Сборка для симуляции — с `-DSIMULATION` (в `UserConfig.cmake`): антидребезг отключён.

## Testbench (`HW_12.srcs/sim_1/new/tb_design_1_wrapper.v`)

- Системный клок 100 МГц, `pix_clk` 25 МГц; `reset_rtl_0` active-low.
- Кнопка нажимается и держится до появления `capture_en`.
- Кадр генерируется на лету: пиксель `(x + 2·y) & 0xFF`, пауза 16 тактов между строками.
- После записи последнего слова все 16 000 слов RAM сравниваются с ожидаемыми;
  выводится `PASS` или первые 10 расхождений. Таймаут 20 мс.

### Запуск

1. В Vitis собрать `app_component` (конфигурация с `SIMULATION`).
2. В Vivado: *Tools → Associate ELF Files → Simulation Sources* → `app_component/build/app_component.elf`.
3. *Run Behavioral Simulation*, *Relaunch* после каждой пересборки программы. Кадр
   занимает ≈ 2,7 мс симулированного времени.

## Скріншоти

![Block Design](https://github.com/user-attachments/assets/ff296fde-23f8-47cf-993f-24cd5477d8b2)
> **Рис. 1** *Block Design*

![Симуляція](https://github.com/user-attachments/assets/1517c047-7918-42db-8596-54491c20e3a2)
> **Рис. 2** *Симуляція*
