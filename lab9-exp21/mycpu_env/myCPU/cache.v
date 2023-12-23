/* module: cache
 * arch:   looongarch-32
 * author: der
 */

`define WIDTH           32
`define BYTE_NUM        4
`define TAG_WIDTH       20
`define INDEX_WIDTH     8
`define OFFSET_WIDTH    4
`define LINE_WIDTH      128
`define WAY_NUM         2
`define BANK_NUM        4
`define TYPE_BYTE       3'b000
`define TYPE_HALF       3'b001
`define TYPE_WORD       3'b010
`define TYPE_CACHE_LINE 3'b100
`define VALID           1'b1
`define DIRTY           1'b1
`define BLANK_LINE      256'b0
`define FULL_STRB       4'hf

module cache (
    input                          clk,
    input                          resetn,

    // CACHE <----> CPU
    input                          valid,        // REQ valid
    input                          op,           // 1 - write;  0 - read
    input                          bypass,       // 1 - uncacheable (bypass);  0 - cacheable
    input  [ `INDEX_WIDTH - 1 : 0] index,        // ADDR[11:4]
    input  [   `TAG_WIDTH - 1 : 0] tag,          // gen(paddr)
    input  [`OFFSET_WIDTH - 1 : 0] offset,       // ADDR[3:0]
    input  [    `BYTE_NUM - 1 : 0] wstrb,        // write strobe(en)
    input  [       `WIDTH - 1 : 0] wdata,        // write DATA
    output                         addr_ok,      // ADDR trans ok - read: ADDR recved; write: ADDR recved & data recved
    output                         data_ok,      // DATA trans ok - read: DATA returned; write: DATA written
    output [       `WIDTH - 1 : 0] rdata,        // read DATA

    // CACHE <----> AXI
    output                         rd_req,       // read REQ valid
    output [                2 : 0] rd_type,      // 3'b000-b; 3'b001-h; 3'b010-w; 3'b100-cache line
    output [       `WIDTH - 1 : 0] rd_addr,      // read begin ADDR
    input                          rd_rdy,       // can recv read REQ (for handshake)
    input                          ret_valid,    // read ret valid
    input                          ret_last,     // read ret last
    input  [       `WIDTH - 1 : 0] ret_data,     // read ret DATA

    output                         wr_req,       // write REQ valid
    output [                2 : 0] wr_type,      // 3'b000-b; 3'b001-h; 3'b010-w; 3'b100-cache line
    output [       `WIDTH - 1 : 0] wr_addr,      // write begin ADDR
    output [    `BYTE_NUM - 1 : 0] wr_wstrb,     // write strobe(en)
    output [  `LINE_WIDTH - 1 : 0] wr_data,      // write DATA
    input                          wr_rdy        // can recv write REQ (for handshake); wr_rdy MUST be ahead of wr_req
);

    /*************************************
     *********** Decalaration ************
     *************************************/

    // main SM
    parameter IDLE    = 5'b00001;
    parameter LOOKUP  = 5'b00010;
    parameter MISS    = 5'b00100;
    parameter REPLACE = 5'b01000;
    parameter REFILL  = 5'b10000;
    reg [4:0] current_state;
    reg [4:0] next_state;
    wire      state_idle    = current_state == IDLE;
    wire      state_lookup  = current_state == LOOKUP;
    wire      state_miss    = current_state == MISS;
    wire      state_replace = current_state == REPLACE;
    wire      state_refill  = current_state == REFILL;

    // write buf SM
    parameter WRBUF_IDLE  = 2'b01;
    parameter WRBUF_WRITE = 2'b10;
    reg [1:0] current_state_wrbuf;
    reg [1:0] next_state_wrbuf;

    // CACHE_TOP <----> RAM - TAGV
    wire                        tagv_we    [`WAY_NUM - 1 : 0];
    wire [`INDEX_WIDTH - 1 : 0] tagv_addr  [`WAY_NUM - 1 : 0];
    wire [      `TAG_WIDTH : 0] tagv_rdata [`WAY_NUM - 1 : 0]; // NO '-1', for V
    wire [      `TAG_WIDTH : 0] tagv_wdata [`WAY_NUM - 1 : 0];

    // CACHE_TOP <----> RAM - DATA
    wire [               3 : 0] data_wmask [`WAY_NUM - 1 : 0][`BANK_NUM - 1 : 0];
    wire [`INDEX_WIDTH - 1 : 0] data_addr  [`WAY_NUM - 1 : 0][`BANK_NUM - 1 : 0];
    wire [      `WIDTH - 1 : 0] data_rdata [`WAY_NUM - 1 : 0][`BANK_NUM - 1 : 0];
    wire [      `WIDTH - 1 : 0] data_wdata [`WAY_NUM - 1 : 0][`BANK_NUM - 1 : 0];
    wire [      `WIDTH - 1 : 0] data_wdata_strbed;
    wire                        data_we    [`WAY_NUM - 1 : 0][`BANK_NUM - 1 : 0];

    // Dirty
    reg  [ `LINE_WIDTH - 1 : 0] dirty [`WAY_NUM - 1 : 0];
    // wire [`INDEX_WIDTH - 1 : 0] dirty_index;

    // cache READ data
    wire                        read_valid [`WAY_NUM - 1 : 0];
    wire [  `TAG_WIDTH - 1 : 0] read_tag   [`WAY_NUM - 1 : 0];
    wire [ `LINE_WIDTH - 1 : 0] read_rdata [`WAY_NUM - 1 : 0];

    // REQ reg
    wire                         req_op_r;
    wire                         req_bypass_r;
    wire [ `INDEX_WIDTH - 1 : 0] req_index_r;
    wire [   `TAG_WIDTH - 1 : 0] req_tag_r;
    wire [`OFFSET_WIDTH - 1 : 0] req_offset_r;
    wire [       `WIDTH - 1 : 0] req_wdata_r;
    wire [    `BYTE_NUM - 1 : 0] req_wstrb_r;

    // REQ reg refresh wen signal
    wire req_refresh = next_state == LOOKUP;

    // WR reg
    wire [ `INDEX_WIDTH - 1 : 0] wr_index_r;
    wire [   `TAG_WIDTH - 1 : 0] wr_tag_r;
    wire [`OFFSET_WIDTH - 1 : 0] wr_offset_r;
    wire [       `WIDTH - 1 : 0] wr_wdata_r;
    wire [    `BYTE_NUM - 1 : 0] wr_wstrb_r;
    wire                         wr_way_r;
    wire [                1 : 0] wr_bank_r;
    wire                         wr_writing;

    // Tag cmp
    wire [           1 : 0] bank;
    wire [           1 : 0] req_bank_r;
    wire                    cache_hit;
    wire                    hit_way;
    wire [`WAY_NUM - 1 : 0] hit;
    // wire [`WAY_NUM - 1 : 0] wr_hit;
    wire                    hit_write;
    wire                    hit_write_hazard;
    wire                    index_offset_remain;

    // LOAD data
    // wire [`WIDTH - 1 : 0] load_word [`WAY_NUM - 1 : 0];
    wire [`WIDTH - 1 : 0] load_res;
    wire                  ret_end;

    // miss(replace)
    wire       replace_way;
    reg  [1:0] ret_cnt;
    wire       need_replace;

    // for interface
    reg  wr_req_r;
    wire rst;

    // LFSR
    reg [7:0] lfsr;

    // genvar
    genvar bk, way;

    // rst
    Reg_norst #(1) reset_cache_inst (clk, ~resetn, rst, 1'b1);


    /**************************************/
    /************** Main FSM **************/
    /**************************************/

    // Block 1 - init
    always @ (posedge clk) begin
        if (rst) begin
            current_state <= IDLE;
        end else begin
            current_state <= next_state;
        end
    end

    // Block 2 - state transition logic
    always @ (*) begin
        case (current_state)
        IDLE:
            if (valid && !hit_write_hazard) begin
                next_state = LOOKUP;
            end
            else begin
                next_state = IDLE;
            end
        LOOKUP:
            if ((!valid || hit_write_hazard) && cache_hit) begin
                next_state = IDLE;
            end
            else if (valid && cache_hit) begin
                next_state = LOOKUP;
            end
            // It seems to be essential (this trans does not exist in book)
            else if (need_replace) begin
                next_state = REPLACE;
            end
            else if (cache_hit == 0) begin   // i.e. ~cache_hit
                next_state = MISS;
            end
        MISS:
            if (wr_rdy) begin
                next_state = REPLACE;
            end
            else begin
                next_state = MISS;
            end
        REPLACE:
            if (rd_rdy) begin
                next_state = REFILL;
            end
            else  begin
                next_state = REPLACE;
            end
        REFILL:
            // bypass write do not need to wait for the data, because it didn't send requests
            if (ret_end || req_bypass_r && req_op_r) begin
                next_state = IDLE;
            end else begin
                next_state = REFILL;
            end
        default:
            next_state = IDLE;
        endcase
    end


    /**************************************/
    /************* WRBUF FSM **************/
    /**************************************/

    // Block 1 - init
    always @ (posedge clk) begin
        if (rst) begin
            current_state_wrbuf <= WRBUF_IDLE;
        end else begin
            current_state_wrbuf <= next_state_wrbuf;
        end
    end

    // Block 2 - state transition logic
    always @ (*) begin
        case (current_state_wrbuf)
        WRBUF_IDLE:
            // main FSM in LOOKUP and Store hit
            if (state_lookup && hit_write) begin
                next_state_wrbuf = WRBUF_WRITE;
            end else begin
                next_state_wrbuf = WRBUF_IDLE;
            end
        WRBUF_WRITE:
            if (hit_write) begin
                next_state_wrbuf = WRBUF_WRITE;
            end else begin
                next_state_wrbuf = WRBUF_IDLE;
            end
        default:
            next_state_wrbuf = WRBUF_IDLE;
        endcase
    end


    /**************************************/
    /************ TAGV CONNECT ************/
    /**************************************/

    assign tagv_we[0]    = ret_end && !req_bypass_r && replace_way == 0; // bypass: not to write
    assign tagv_we[1]    = ret_end && !req_bypass_r && replace_way == 1;
    assign tagv_wdata[0] = {req_tag_r, `VALID};
    assign tagv_wdata[1] = {req_tag_r, `VALID};
    assign tagv_addr[0]  = (state_idle || state_lookup) ? index : req_index_r;
    assign tagv_addr[1]  = (state_idle || state_lookup) ? index : req_index_r;

    generate
        for (way = 0; way < `WAY_NUM; way = way + 1) begin : TAGV_CONNET_WAY
            TAGV_RAM tagv_ram_inst(
                .clka   (clk            ),
                .wea    (tagv_we[way]   ),
                .addra  (tagv_addr[way] ),
                .dina   (tagv_wdata[way]),
                .douta  (tagv_rdata[way]),
                .ena    (1'b1           )
            );
        end
    endgenerate

    for (way = 0; way < `WAY_NUM; way = way + 1) begin
        assign read_valid[way] = tagv_rdata[way][0];
        assign read_tag[way]   = tagv_rdata[way][`TAG_WIDTH : 1];
    end

    /**************************************/
    /************ DATA CONNECT ************/
    /**************************************/

    generate
        for (way = 0; way < `WAY_NUM; way = way + 1) begin : DATA_CONNET_WAY
            for (bk = 0; bk < `BANK_NUM; bk = bk + 1) begin : DATA_CONNECT_BANK
                DATA_RAM data_ram_inst (
                    .clka   (clk             ),
                    .wea    (data_wmask[way][bk]),
                    .addra  (data_addr[way][bk] ),
                    .dina   (data_wdata[way][bk]),
                    .douta  (data_rdata[way][bk]),
                    .ena    (1'b1            )
                );
            end
        end
    endgenerate

    for (way = 0; way < `WAY_NUM; way = way + 1) begin
        for (bk = 0; bk < `BANK_NUM; bk = bk + 1) begin
            assign data_wdata[way][bk] = wr_writing                      ? wr_wdata_r :
                                         (req_bank_r != bk || !req_op_r) ? ret_data   :
                                         data_wdata_strbed
            ;
            assign data_addr[way][bk]  = (state_idle || state_lookup) ? index : req_index_r;
            assign data_wmask[way][bk] = {4{wr_writing && wr_bank_r == bk && wr_way_r == way}} & wr_wstrb_r
                                       | {4{ret_valid && ret_cnt == bk && replace_way == way}} & 4'hf
            ;
            assign data_we[way][bk] = wr_writing
                ? (wr_way_r == way && wr_bank_r == bk)
                : (replace_way == way && ret_cnt == bk && ret_valid)
            ;
        end
    end

    for (way = 0; way < `WAY_NUM; way = way + 1) begin
        assign read_rdata[way] = {
            data_rdata[way][3],
            data_rdata[way][2],
            data_rdata[way][1],
            data_rdata[way][0]
        };
    end

    assign data_wdata_strbed = {
        wr_wstrb_r[3] ? wr_wdata_r[31:24] : ret_data[31:24],
        wr_wstrb_r[2] ? wr_wdata_r[23:16] : ret_data[23:16],
        wr_wstrb_r[1] ? wr_wdata_r[15: 8] : ret_data[15: 8],
        wr_wstrb_r[0] ? wr_wdata_r[ 7: 0] : ret_data[ 7: 0]
    };
    
    assign load_res = data_rdata[hit_way][req_bank_r];

    /**************************************/
    /*************** DIRTY ****************/
    /**************************************/

    always @ (posedge clk) begin
        if (rst) begin
            dirty[0] <= `BLANK_LINE;
            dirty[1] <= `BLANK_LINE;
        end else if (wr_writing) begin // bypass: not to write
            dirty[wr_way_r][wr_index_r] <= `DIRTY;
        end else if (ret_end && !req_bypass_r) begin
            dirty[replace_way][req_index_r] <= req_op_r;
        end
    end


    /**************************************/
    /*** LINEAR FEEDBACK SHIFT REGISTER ***/
    /**************************************/

     always @ (posedge clk) begin
        if (rst) begin
            lfsr <= 8'b11111111;
        end
        else if (ret_end) begin
            lfsr <= {lfsr[5:0], lfsr[0] ^ lfsr[1]};
        end
    end


    /**************************************/
    /*********** TAG CMP LOGIC ************/
    /**************************************/

    assign hit[0]               = read_valid[0] && (read_tag[0] == req_tag_r);
    assign hit[1]               = read_valid[1] && (read_tag[1] == req_tag_r);
    assign cache_hit            = (hit[0] || hit[1]) && !req_bypass_r; // bypass: uncacheable
    assign hit_way              = hit[0] ? 0 : 1;
    assign hit_write            = cache_hit && req_op_r; // bypass: cache not hit
    assign hit_write_hazard     = valid && !op &&
                                (state_lookup && hit_write && index_offset_remain
                              || wr_writing && (bank == req_bank_r))
    ; // bypass: NO hit write, NO wr_writing
    assign index_offset_remain  = {index, offset} == {req_index_r, req_offset_r};


    /**************************************/
    /************** REQ BUF ***************/
    /**************************************/

    assign req_refresh = next_state == LOOKUP;
    Reg #(            1,             1'b0) req_op_r_inst     (clk, rst, op,     req_op_r,     req_refresh);
    Reg #(            1,             1'b0) req_bypass_r_inst (clk, rst, bypass, req_bypass_r, req_refresh);
    Reg #( `INDEX_WIDTH,  `INDEX_WIDTH'b0) req_index_r_inst  (clk, rst, index,  req_index_r,  req_refresh);
    Reg #(   `TAG_WIDTH,    `TAG_WIDTH'b0) req_tag_r_inst    (clk, rst, tag,    req_tag_r,    req_refresh);
    Reg #(`OFFSET_WIDTH, `OFFSET_WIDTH'b0) req_offset_r_inst (clk, rst, offset, req_offset_r, req_refresh);
    Reg #(       `WIDTH,        `WIDTH'b0) req_wdata_r_inst  (clk, rst, wdata,  req_wdata_r,  req_refresh);
    Reg #(    `BYTE_NUM,     `BYTE_NUM'b0) req_wstrb_r_inst  (clk, rst, wstrb,  req_wstrb_r,  req_refresh);

    assign bank       = offset[3:2];
    assign req_bank_r = req_offset_r[3:2];


    /**************************************/
    /************** WR BUF ****************/
    /**************************************/

    Reg #( `INDEX_WIDTH,  `INDEX_WIDTH'b0) wr_index_r_inst  (clk, rst, req_index_r,  wr_index_r,  hit_write);
    Reg #(   `TAG_WIDTH,    `TAG_WIDTH'b0) wr_tag_r_inst    (clk, rst, req_tag_r,    wr_tag_r,    hit_write);
    Reg #(`OFFSET_WIDTH, `OFFSET_WIDTH'b0) wr_offset_r_inst (clk, rst, req_offset_r, wr_offset_r, hit_write);
    Reg #(       `WIDTH,        `WIDTH'b0) wr_wdata_r_inst  (clk, rst, req_wdata_r,  wr_wdata_r,  hit_write);
    Reg #(    `BYTE_NUM,     `BYTE_NUM'b0) wr_wstrb_r_inst  (clk, rst, req_wstrb_r,  wr_wstrb_r,  hit_write);
    Reg #(            1,             1'b0) wr_way_r_inst    (clk, rst, hit_way,      wr_way_r,    hit_write);
    Reg #(            2,             2'b0) wr_bank_r_inst   (clk, rst, req_bank_r,   wr_bank_r,   hit_write);

    always @ (posedge clk) begin
        if (rst) begin
            wr_req_r <= 1'b0;
        end
        else if (state_miss && next_state == REPLACE) begin
            wr_req_r <= 1'b1;
        end
        else if (wr_rdy) begin
            wr_req_r <= 1'b0;
        end
    end

    assign wr_writing = current_state_wrbuf == WRBUF_WRITE; // make sure bypass DO NOT write


    /**************************************/
    /********** MISS(REPLACE) *************/
    /**************************************/

    always @ (posedge clk) begin
        if (rst) begin
            ret_cnt <= 0;
        end else if (ret_valid && !ret_last) begin
            ret_cnt <= ret_cnt + 1;
        end else if (ret_end) begin
            ret_cnt <= 0;
        end
    end
    assign replace_way  = lfsr[0];
    assign need_replace = !dirty[replace_way][req_index_r]
                       || !read_valid[replace_way]
                       || req_bypass_r && req_op_r;


    /**************************************/
    /************** INTERFACE *************/
    /**************************************/

    wire        rd_req_cache;
    wire [ 2:0] rd_type_cache;
    wire [31:0] rd_addr_cache;
    wire        rd_req_bypass;
    wire [ 2:0] rd_type_bypass;
    wire [31:0] rd_addr_bypass;

    // READ
    assign rd_req_cache   = state_replace;
    assign rd_type_cache  = `TYPE_CACHE_LINE;
    assign rd_addr_cache  = {req_tag_r, req_index_r, `OFFSET_WIDTH'b0};

    assign rd_req_bypass  = state_replace && !req_op_r; // only bypass read need to read from AXI
    assign rd_type_bypass = {3{req_wstrb_r == 4'b1111                            }} & `TYPE_WORD
                          | {3{req_wstrb_r == 4'b0011 || req_wstrb_r == 4'b1100  }} & `TYPE_HALF
                        //   | {3{req_wstrb_r == 4'b0001 || req_wstrb_r == 4'b0010||
                        //        req_wstrb_r == 4'b0100 || req_wstrb_r == 4'b1000  }} & `TYPE_BYTE // xxx&0
    ;
    assign rd_addr_bypass = {req_tag_r, req_index_r, req_offset_r[`OFFSET_WIDTH - 1 : 2],
                                req_offset_r[1:0] & (
                                    {(rd_type_bypass == `TYPE_BYTE) | (rd_type_bypass == `TYPE_HALF),
                                     (rd_type_bypass == `TYPE_BYTE)})}
    ; // clear corresponding bytes

    assign {rd_req, rd_type, rd_addr} = req_bypass_r
        ? {rd_req_bypass, rd_type_bypass, rd_addr_bypass}
        : {rd_req_cache,  rd_type_cache,  rd_addr_cache}
    ;
    assign rdata    = ret_valid ? ret_data : load_res; //

    // WRITE
    assign wr_req   = wr_req_r;
    assign wr_type  = `TYPE_CACHE_LINE;
    assign wr_addr  = {read_tag[replace_way], req_index_r, `OFFSET_WIDTH'b0};
    assign wr_wstrb = `FULL_STRB;
    assign wr_data  = {data_rdata[replace_way][3],
                       data_rdata[replace_way][2],
                       data_rdata[replace_way][1],
                       data_rdata[replace_way][0]}
    ;

    // OK
    assign addr_ok = state_idle || state_lookup && valid && cache_hit && (op || (!op && !hit_write_hazard)); // bypass -> cache miss
    assign data_ok = (state_lookup && (cache_hit || req_op_r) ||
                        state_refill && !req_op_r && ret_valid && (ret_cnt == req_bank_r || req_bypass_r))
    ; // if bypass, there will be no burst (all data in only one beat)

    // Interface combination
    assign ret_end = ret_valid && ret_last;


    /**************************************/
    /************** RESERVED **************/
    /**************************************/
    
endmodule
 