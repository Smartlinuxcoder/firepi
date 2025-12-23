module top (
    input  clk_50mhz,
    input  uart_rx, // UART0
    output uart_tx,
    input  uart1_rx, // UART1
    output uart1_tx,
    output led_out, // Orange
    output led_solved // Green
);

    reg [24:0] counter = 0;
    always @(posedge clk_50mhz) counter <= counter + 1;
    wire slow_clk = counter[22];

    // UART
    wire [7:0] rx_byte;
    wire rx_valid;
    reg [7:0] tx_byte;
    reg tx_start = 0;
    wire tx_busy;

    uart_rx #(.CLK_FREQ(50000000), .BAUD_RATE(115200)) u_rx (
        .clk(clk_50mhz),
        .rx(uart_rx),
        .data(rx_byte),
        .valid(rx_valid)
    );

    uart_tx #(.CLK_FREQ(50000000), .BAUD_RATE(115200)) u_tx (
        .clk(clk_50mhz),
        .start(tx_start),
        .data(tx_byte),
        .tx(uart_tx),
        .busy(tx_busy)
    );

    // UART1
    wire [7:0] rx1_byte;
    wire rx1_valid;
    reg [7:0] tx1_byte;
    reg tx1_start = 0;
    wire tx1_busy;

    uart_rx #(.CLK_FREQ(50000000), .BAUD_RATE(115200)) u_rx1 (
        .clk(clk_50mhz),
        .rx(uart1_rx),
        .data(rx1_byte),
        .valid(rx1_valid)
    );

    uart_tx #(.CLK_FREQ(50000000), .BAUD_RATE(115200)) u_tx1 (
        .clk(clk_50mhz),
        .start(tx1_start),
        .data(tx1_byte),
        .tx(uart1_tx),
        .busy(tx1_busy)
    );

    // State (2q)
    // Q2.14: 1.0 = 16384
    reg signed [15:0] amp [0:3]; 
    // INV_SQRT_2 = 11586 (≈0.707)
    localparam signed [15:0] INV_SQRT_2 = 11586;
    localparam signed [15:0] ONE = 16384;

    // FSM
    localparam S_IDLE = 0;
    localparam S_READ_CMD = 1;
    localparam S_GET_ARG1 = 2;
    localparam S_GET_ARG2 = 3;
    localparam S_EXEC_H = 4;
    localparam S_EXEC_CNOT = 5;
    localparam S_EXEC_MEASURE_CALC = 6;
    localparam S_SEND_RESP = 7;
    localparam S_WAIT_TX_START = 8;
    localparam S_RESET_Q = 9;
    localparam S_WAIT_TX_END = 10;
    localparam S_EXEC_MEASURE_DECIDE = 11;
    
    // Sync
    localparam S_SYNC_PREPARE = 12;
    localparam S_SYNC_HEADER_WAIT_START = 13;
    localparam S_SYNC_HEADER_WAIT_END = 14;
    localparam S_SYNC_SEND_BODY = 15;
    localparam S_SYNC_BODY_WAIT_START = 16;
    localparam S_SYNC_BODY_WAIT_END = 17;
    localparam S_APPLY_REMOTE = 18;

    reg [4:0] state = S_IDLE;
    reg [7:0] cmd_reg;
    reg [7:0] arg1;
    reg [7:0] arg2;
    
    // Resp buf
    reg [7:0] resp_buffer [0:3]; // "0","0","\r","\n"
    reg [2:0] resp_idx = 0;
    reg [2:0] resp_len = 0;

    reg processing = 0;
    reg green_state = 1; // 1=Measured, 0=Superpos

    // Sync buf
    reg [7:0] sync_tx_buf [0:9];
    reg [3:0] sync_tx_idx = 0;
    
    reg [7:0] sync_rx_buf [0:9];
    reg [3:0] sync_rx_idx = 0;
    reg remote_update_ready = 0;
    reg [1:0] rx1_state = 0; // 0=Idle,1=Data

    // UART1 RX
    always @(posedge clk_50mhz) begin
        if (rx1_valid) begin
            case (rx1_state)
                0: begin // Header
                    if (rx1_byte == 8'hAA) begin
                        sync_rx_idx <= 0;
                        rx1_state <= 1;
                    end
                end
                1: begin // Body
                    sync_rx_buf[sync_rx_idx] <= rx1_byte;
                    if (sync_rx_idx == 9) begin
                        remote_update_ready <= 1;
                        rx1_state <= 0;
                    end else begin
                        sync_rx_idx <= sync_rx_idx + 1;
                    end
                end
            endcase
        end
        
        // Clear
        if (state == S_APPLY_REMOTE) begin
            remote_update_ready <= 0;
        end
    end

    // LFSR
    reg [15:0] lfsr = 16'hACE1;
    always @(posedge clk_50mhz) begin
        lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
    end

    // Meas tmp
    reg [31:0] meas_sq0, meas_sq1, meas_sq2, meas_sq3;
    reg [15:0] meas_rnd;

    initial begin
        amp[0] = ONE; amp[1] = 0; amp[2] = 0; amp[3] = 0;
    end

    always @(posedge clk_50mhz) begin
        tx_start <= 0;
        tx1_start <= 0;

        case (state)
            S_IDLE: begin
                processing <= 0;
                if (remote_update_ready) begin
                    processing <= 1;
                    state <= S_APPLY_REMOTE;
                end else if (rx_valid) begin
                    cmd_reg <= rx_byte;
                    processing <= 1;
                    state <= S_READ_CMD;
                end
            end

            S_APPLY_REMOTE: begin
                // Apply
                amp[0] <= {sync_rx_buf[0], sync_rx_buf[1]};
                amp[1] <= {sync_rx_buf[2], sync_rx_buf[3]};
                amp[2] <= {sync_rx_buf[4], sync_rx_buf[5]};
                amp[3] <= {sync_rx_buf[6], sync_rx_buf[7]};
                green_state <= sync_rx_buf[8][0];
                
                state <= S_IDLE;
            end

            S_READ_CMD: begin
                case (cmd_reg)
                    "r": state <= S_RESET_Q; // Reset
                    "h": state <= S_GET_ARG1; // H
                    "c": state <= S_GET_ARG1; // CNOT
                    "m": state <= S_EXEC_MEASURE_CALC; // Meas
                    "e": begin
                        // Sync
                        resp_buffer[0] <= "K"; resp_buffer[1] <= "\r"; resp_buffer[2] <= "\n";
                        resp_len <= 3;
                        resp_idx <= 0;
                        state <= S_SYNC_PREPARE;
                    end
                    default: state <= S_IDLE;
                endcase
            end

            S_GET_ARG1: begin
                if (rx_valid) begin
                    arg1 <= rx_byte; // '0'/'1'
                    if (cmd_reg == "h") state <= S_EXEC_H;
                    else if (cmd_reg == "c") state <= S_GET_ARG2;
                end
            end

            S_GET_ARG2: begin
                if (rx_valid) begin
                    arg2 <= rx_byte;
                    state <= S_EXEC_CNOT;
                end
            end

            S_RESET_Q: begin
                amp[0] <= ONE; amp[1] <= 0; amp[2] <= 0; amp[3] <= 0;
                green_state <= 1;
                // Ack
                resp_buffer[0] <= "K"; resp_buffer[1] <= "\r"; resp_buffer[2] <= "\n";
                resp_len <= 3;
                resp_idx <= 0;
                state <= S_SEND_RESP;
            end

            S_EXEC_H: begin
                // H
                green_state <= 0; // Superpos
                
                if (arg1 == "0") begin
                    // Q0
                    
                    // Mix
                    amp[0] <= ($signed({{16{amp[0][15]}}, amp[0]}) + $signed({{16{amp[1][15]}}, amp[1]})) * $signed({{16{INV_SQRT_2[15]}}, INV_SQRT_2}) >>> 14;
                    amp[1] <= ($signed({{16{amp[0][15]}}, amp[0]}) - $signed({{16{amp[1][15]}}, amp[1]})) * $signed({{16{INV_SQRT_2[15]}}, INV_SQRT_2}) >>> 14;
                    amp[2] <= ($signed({{16{amp[2][15]}}, amp[2]}) + $signed({{16{amp[3][15]}}, amp[3]})) * $signed({{16{INV_SQRT_2[15]}}, INV_SQRT_2}) >>> 14;
                    amp[3] <= ($signed({{16{amp[2][15]}}, amp[2]}) - $signed({{16{amp[3][15]}}, amp[3]})) * $signed({{16{INV_SQRT_2[15]}}, INV_SQRT_2}) >>> 14;
                end else if (arg1 == "1") begin
                    // Q1
                    
                    amp[0] <= ($signed({{16{amp[0][15]}}, amp[0]}) + $signed({{16{amp[2][15]}}, amp[2]})) * $signed({{16{INV_SQRT_2[15]}}, INV_SQRT_2}) >>> 14;
                    amp[2] <= ($signed({{16{amp[0][15]}}, amp[0]}) - $signed({{16{amp[2][15]}}, amp[2]})) * $signed({{16{INV_SQRT_2[15]}}, INV_SQRT_2}) >>> 14;
                    amp[1] <= ($signed({{16{amp[1][15]}}, amp[1]}) + $signed({{16{amp[3][15]}}, amp[3]})) * $signed({{16{INV_SQRT_2[15]}}, INV_SQRT_2}) >>> 14;
                    amp[3] <= ($signed({{16{amp[1][15]}}, amp[1]}) - $signed({{16{amp[3][15]}}, amp[3]})) * $signed({{16{INV_SQRT_2[15]}}, INV_SQRT_2}) >>> 14;
                end
                
                resp_buffer[0] <= "K"; resp_buffer[1] <= "\r"; resp_buffer[2] <= "\n";
                resp_len <= 3;
                resp_idx <= 0;
                state <= S_SEND_RESP;
            end

            S_EXEC_CNOT: begin
                // CNOT
                green_state <= 0; // Entangled
                
                if (arg1 == "0" && arg2 == "1") begin
                    // Ctrl Q0 -> Q1
                    // swap 1,3
                    amp[1] <= amp[3];
                    amp[3] <= amp[1];
                end else if (arg1 == "1" && arg2 == "0") begin
                    // Ctrl Q1 -> Q0
                    // swap 2,3
                    amp[2] <= amp[3];
                    amp[3] <= amp[2];
                end

                resp_buffer[0] <= "K"; resp_buffer[1] <= "\r"; resp_buffer[2] <= "\n";
                resp_len <= 3;
                resp_idx <= 0;
                state <= S_SEND_RESP;
            end

            S_EXEC_MEASURE_CALC: begin
                // Meas calc
                meas_sq0 <= $signed({{16{amp[0][15]}}, amp[0]}) * $signed({{16{amp[0][15]}}, amp[0]});
                meas_sq1 <= $signed({{16{amp[1][15]}}, amp[1]}) * $signed({{16{amp[1][15]}}, amp[1]});
                meas_sq2 <= $signed({{16{amp[2][15]}}, amp[2]}) * $signed({{16{amp[2][15]}}, amp[2]});
                meas_sq3 <= $signed({{16{amp[3][15]}}, amp[3]}) * $signed({{16{amp[3][15]}}, amp[3]});
                
                // RNG
                meas_rnd <= lfsr;
                
                state <= S_EXEC_MEASURE_DECIDE;
            end

            S_EXEC_MEASURE_DECIDE: begin
                // Born
                if (meas_rnd[13:0] < (meas_sq0 >> 14)) begin
                    resp_buffer[0] <= "0"; resp_buffer[1] <= "0";
                    amp[0] <= ONE; amp[1] <= 0; amp[2] <= 0; amp[3] <= 0;
                end else if (meas_rnd[13:0] < ((meas_sq0 + meas_sq1) >> 14)) begin
                    resp_buffer[0] <= "0"; resp_buffer[1] <= "1";
                    amp[0] <= 0; amp[1] <= ONE; amp[2] <= 0; amp[3] <= 0;
                end else if (meas_rnd[13:0] < ((meas_sq0 + meas_sq1 + meas_sq2) >> 14)) begin
                    resp_buffer[0] <= "1"; resp_buffer[1] <= "0";
                    amp[0] <= 0; amp[1] <= 0; amp[2] <= ONE; amp[3] <= 0;
                end else begin
                    resp_buffer[0] <= "1"; resp_buffer[1] <= "1";
                    amp[0] <= 0; amp[1] <= 0; amp[2] <= 0; amp[3] <= ONE;
                end

                resp_buffer[2] <= "\r"; 
                resp_buffer[3] <= "\n";
                resp_len <= 4;
                resp_idx <= 0;
                green_state <= 1; // Measured
                state <= S_SYNC_PREPARE; // Sync
            end

            // Sync
            S_SYNC_PREPARE: begin
                // Tx buf
                sync_tx_buf[0] <= amp[0][15:8]; sync_tx_buf[1] <= amp[0][7:0];
                sync_tx_buf[2] <= amp[1][15:8]; sync_tx_buf[3] <= amp[1][7:0];
                sync_tx_buf[4] <= amp[2][15:8]; sync_tx_buf[5] <= amp[2][7:0];
                sync_tx_buf[6] <= amp[3][15:8]; sync_tx_buf[7] <= amp[3][7:0];
                sync_tx_buf[8] <= {7'b0, green_state};
                sync_tx_buf[9] <= 8'h00; // Pad
                
                sync_tx_idx <= 0;
                
                // Header 0xAA
                if (!tx1_busy) begin
                    tx1_byte <= 8'hAA;
                    tx1_start <= 1;
                    state <= S_SYNC_HEADER_WAIT_START;
                end
            end

            S_SYNC_HEADER_WAIT_START: begin
                tx1_start <= 0;
                if (tx1_busy) state <= S_SYNC_HEADER_WAIT_END;
            end

            S_SYNC_HEADER_WAIT_END: begin
                if (!tx1_busy) begin
                    state <= S_SYNC_SEND_BODY;
                end
            end

            S_SYNC_SEND_BODY: begin
                if (!tx1_busy) begin
                    tx1_byte <= sync_tx_buf[sync_tx_idx];
                    tx1_start <= 1;
                    state <= S_SYNC_BODY_WAIT_START;
                end
            end

            S_SYNC_BODY_WAIT_START: begin
                tx1_start <= 0;
                if (tx1_busy) state <= S_SYNC_BODY_WAIT_END;
            end

            S_SYNC_BODY_WAIT_END: begin
                if (!tx1_busy) begin
                    if (sync_tx_idx < 9) begin
                        sync_tx_idx <= sync_tx_idx + 1;
                        state <= S_SYNC_SEND_BODY;
                    end else begin
                        state <= S_SEND_RESP;
                    end
                end
            end

            S_SEND_RESP: begin
                if (!tx_busy) begin
                    tx_byte <= resp_buffer[resp_idx];
                    tx_start <= 1;
                    state <= S_WAIT_TX_START;
                end
            end

            S_WAIT_TX_START: begin
                tx_start <= 0;
                if (tx_busy) state <= S_WAIT_TX_END;
            end

            S_WAIT_TX_END: begin
                if (!tx_busy) begin
                    // Byte done
                    if (resp_idx < resp_len - 1) begin
                        resp_idx <= resp_idx + 1;
                        state <= S_SEND_RESP;
                    end else begin
                        state <= S_IDLE;
                    end
                end
            end
        endcase
    end

    // LED
    assign led_solved = (!processing) && green_state;
    assign led_out = processing ? counter[22] : (!green_state);

endmodule