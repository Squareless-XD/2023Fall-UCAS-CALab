`define RADDR	5
`define BYTE	8
`define HALF	16
`define WORD	32
`define WIDTH	32
`define DWIDTH	64
`define R0		5'b00000
`define TRUE	1'b1
`define FALSE	1'b0

module mycpu_top(
	input  wire        clk,
	input  wire        resetn,
	// inst sram interface
	output wire        inst_sram_en,	// instruction SRAM port enable pin
	output wire [ 3:0] inst_sram_we,	// instruction SRAM byte-writes
	output wire [31:0] inst_sram_addr,
	output wire [31:0] inst_sram_wdata,
	input  wire [31:0] inst_sram_rdata,
	// data sram interface
	output wire        data_sram_en,	// data SRAM port enable pin
	output wire [ 3:0] data_sram_we,	// data SRAM byte-writes
	output wire [31:0] data_sram_addr,
	output wire [31:0] data_sram_wdata,
	input  wire [31:0] data_sram_rdata,
	// trace debug interface
	output wire [31:0] debug_wb_pc,
	output wire [ 3:0] debug_wb_rf_we,
	output wire [ 4:0] debug_wb_rf_wnum,
	output wire [31:0] debug_wb_rf_wdata
);

/* --------------------------------------
	Declarations
  ------------------------------------ */

	parameter Stage_Num = 5; // number of pipeline stages

	reg reset;

	// pipeline controllers 
	wire [Stage_Num - 1 : 0] pipe_ready_go;		// 0: IF. 1: ID. 2: EX. 3: MEM. 4: WB.
	wire [Stage_Num - 1 : 0] pipe_allowin;		// 0: IF. 1: ID. 2: EX. 3: MEM. 4: WB.
	wire [Stage_Num - 2 : 0] pipe_tonext_valid;	// 0: IF. 1: ID. 2: EX. 3: MEM. 4: WB. "4" bits
	reg  [Stage_Num - 1 : 0] pipe_valid;		// 0: IF. 1: ID. 2: EX. 3: MEM. 4: WB.

	// next PC calculation
	wire                  br_taken; // branch taken or not
	wire [`WIDTH - 1 : 0] br_target; // branch target, PC+4 or branch target
	wire [`WIDTH - 1 : 0] seq_pc; // sequential PC value, PC+4
	wire [`WIDTH - 1 : 0] nextpc; // next PC value, branch target

	// register equality detection
	wire rd_EX_r1_eq, rd_MEM_r1_eq, rd_WB_r1_eq; // r1 in ID stage is equal to r1 in EX/MEM/WB stage
	wire rd_EX_r2_eq, rd_MEM_r2_eq, rd_WB_r2_eq; // r2 in ID stage is equal to r2 in EX/MEM/WB stage

	// hazard detection
	wire hzd_alu_EX_r1, hzd_alu_MEM_r1; // ALU type hazard for r1
	wire hzd_alu_EX_r2, hzd_alu_MEM_r2; // ALU type hazard for r2
	wire hzd_ld_mul_csr_EX_r1, hzd_ld_mul_csr_MEM_r1; // load type hazard for r1
	wire hzd_ld_mul_csr_EX_r2, hzd_ld_mul_csr_MEM_r2; // load type hazard for r2
	wire hzd_WB_r1, hzd_WB_r2;
	wire hzd_csrw_EX, hzd_csrw_MEM, hzd_csrw_WB;

	wire calc_done; // calculation ready, for mul/div instructions
	wire ID_hazard; // ID stage installed/bubbled for hazard

	/*--- IF declaration ---*/
	wire [`WIDTH - 1 : 0] inst_final;
	wire [`WIDTH - 1 : 0] pc; // sequential PC value, PC+4
	wire [         5 : 0] ecode;
	/*--- IF declaration ---*/

	/*--- ID declaration ---*/
	wire [        12 : 0] alu_op; // ALU operation code
	wire [`WIDTH - 1 : 0] rj_value, rkd_value, imm; // rj, rkd, immediate
	wire [`WIDTH - 1 : 0] pc_ID; // PC

	wire [         3 : 0] op_25_22; // opcode[25:22]
	wire [         6 : 0] op_21_15; // opcode[21:15]
	wire [`RADDR - 1 : 0] rf_raddr1, rf_raddr2, dest; // register file read address
	wire                  byte_we, half_we, word_we, signed_we; // byte, half, word, signed write enable
	wire                  ld_inst, st_inst, div_inst, mul_inst, ertn_inst, csr_inst, rdcn_inst; // load, store, div, mul, ertn, csr, syscall
	wire                  br_taken_sure, br_taken_yes, br_taken_no; // branch taken or not
	wire                  src1_is_pc, src2_is_imm, src2_is_4, br_src_sel; // source operand control signal
	wire                  res_from_mem, gpr_we, mem_we; // result from memory, general register write enable, memory write enable
	wire                  rf_ren1, rf_ren2; // register file read enable
	wire [         5 : 0] ecode_ID_m; // exception code
	wire [         2 : 0] rdcn_op;
	wire                  csr_we, csr_wmask_en; // CSR write enable, CSR write mask enable
	wire                  has_int_ID;
	/*--- ID declaration ---*/

	/*--- EX declaration ---*/
	wire [`WIDTH - 1 : 0] pc_EX, rj_value_EX, rkd_value_EX; // PC, ALU result, rkd
	wire [`WIDTH - 1 : 0] alu_div_rdcntv_result; // PC, rkd
	wire [`DWIDTH - 1: 0] mul_result; // to WB - skip MEM
	wire [         3 : 0] op_25_22_EX; // opcode[25:22]
	wire [`RADDR - 1 : 0] rf_raddr1_EX, rf_raddr2_EX, dest_EX; // register file read address
	wire                  ld_inst_EX, st_inst_EX, csr_inst_EX, ertn_inst_EX, rdcn_inst_EX; // load, store, ertn, csr, syscall
	wire				  mul_inst_EX;
	wire [         2 : 0] mul_op_EX;
	wire                  res_from_mem_EX, gpr_we_EX, mem_we_EX; // result from memory, general register write enable, memory write enable
	wire                  has_int_EX;
	wire				  EX_ex_ertn;

	// wire                  br_taken, calc_done; // calculation ready, for mul/div instructions
	wire [         5 : 0] ecode_EX_m;
	wire [         2 : 0] rdcn_op_EX;

	wire                  csr_we_EX, csr_wmask_en_EX;
	wire [        13 : 0] csr_code_EX;
	/*--- EX declaration ---*/

	/*--- MEM declaration ---*/
	wire [`WIDTH - 1 : 0] pc_MEM, alu_div_rdcntv_result_MEM, rj_value_MEM, rkd_value_MEM; // PC, ALU result, rkd
	wire [`RADDR - 1 : 0] rf_raddr1_MEM, rf_raddr2_MEM, dest_MEM; // register file read address
	wire [         3 : 0] mask_dataram; // data memory byte-write mask
	wire                  byte_we_MEM, half_we_MEM, word_we_MEM, signed_we_MEM; // byte, half, word, signed write enable
	wire                  ld_inst_MEM, csr_inst_MEM, ertn_inst_MEM, rdcn_inst_MEM; // load, csr, ertn, syscall
	wire				  mul_inst_MEM;
	wire [         2 : 0] mul_op_MEM;
	wire				  rdcn_op_MEM;
	wire                  res_from_mem_MEM, gpr_we_MEM; // result from memory, general register write enable
	wire                  has_int_MEM;
	wire				  MEM_ex_ertn;

	wire [         5 : 0] ecode_MEM_m;
	wire                  csr_we_MEM, csr_wmask_en_MEM;
	wire [        13 : 0] csr_code_MEM;
	/*--- MEM declaration ---*/

	/*--- WB declaration ---*/
	wire                  gpr_we_WB; // general register write enable

	wire                  rf_we;    // register file write enable
	wire [`RADDR - 1 : 0] rf_waddr; // register file write address
	wire [`RADDR - 1 : 0] dest_WB;  // destination register number
	wire [`WIDTH - 1 : 0] rf_wdata; // register file write data
	wire [`WIDTH - 1 : 0] pc_WB;

	// wire [         8 : 0] csr_waddr;
	// wire 				  csr_we_WB;
	// wire [`WIDTH - 1 : 0] csr_wmask;
	// wire [`WIDTH - 1 : 0] csr_wvalue;
	// wire [         8 : 0] csr_raddr;
	// wire 				  ertn_flush;
	// wire 				  WB_ex;
	// wire [        31 : 0] WB_vaddr;
	// wire [         5 : 0] ecode_noint;
	// wire [         8 : 0] WB_esubcode;

	wire 				  ertn_inst_WB;
	wire				  has_int_WB;
	wire                  rdcn_inst_WB;
/*--- WB declaration ---*/

	assign debug_wb_pc = pc_WB;
	// rdcn_inst
	reg  [`DWIDTH - 1 : 0] tick;


/* --------------------------------------------------------------------
	reset signal generation
  ------------------------------------------------------------------ */

	always @(posedge clk) begin
		reset <= ~resetn;
	end

	// rdcn tick
	always @ (posedge clk) begin
		if(reset) 
			tick <= 64'b0;
 		else
			tick <= tick + 64'b1;
	end


/* --------------------------------------------------------------------
	Control and Status Registers Module
  ------------------------------------------------------------------ */

	wire [ 8:0] csr_waddr; // WB
	wire [ 8:0] csr_raddr; // WB
	wire 		csr_we_WB; // WB
	wire [31:0] csr_wmask; // WB
	wire [31:0] csr_wvalue; // WB
	wire [31:0] csr_rvalue; // output WB
	wire [31:0] cpuid = 32'b0; // not certain now
	wire [ 7:0] hw_int_in = 8'b0; // not certain now
	wire 		ipi_int_in = 1'b0; // not certain now
	wire [31:0] ex_entry; // output EX
	wire 		has_int; // output, not certain now
	wire [31:0] era_value; // output EX
	wire 		ertn_flush; // WB
	wire 		WB_ex; // WB
	// wire [31:0] WB_pc; // WB
	wire [31:0] WB_vaddr; // WB
	wire [ 5:0] ecode_noint; // WB
	wire [ 5:0] WB_ecode;
	wire [ 8:0] WB_esubcode; // WB
	assign WB_ecode = ecode_noint;
	csr csr_module_inst (
		.clk			(clk),
		.rst			(reset),

		// Ports for inst access
		.csr_waddr		(csr_waddr), 	// write address
		.csr_raddr		(csr_raddr),	// read  address
		.csr_we			(csr_we_WB), 		// write enable
		.csr_wmask		(csr_wmask), 	// write mask
		.csr_wvalue		(csr_wvalue),	// value to be written
		.csr_rvalue		(csr_rvalue),	// value read

		// Ports for interacting with CPU hardware
		.cpuid			(cpuid),		// CPU ID, just 0 is OK
		.hw_int_in		(hw_int_in), 	// hardware interrupt
		.ipi_int_in		(ipi_int_in),	// IPI interrupt (0)
		.ex_entry		(ex_entry), 	// exception entry
		.has_int		(has_int), 		// has interrupt
		.era_value		(era_value),	// exception return address
		.ertn_flush		(ertn_flush),	// ERTN inst (ertn)
		.WB_ex			(WB_ex), 		// exc from WB
		.WB_pc			(pc_WB),
		.WB_vaddr		(WB_vaddr), 	// bad vaddr
		.WB_ecode		(WB_ecode),		// exception code
		.WB_esubcode	(WB_esubcode)
	);

	// module csr (
	// 	input	wire		clk,
	// 	input	wire		rst,

	// 	// Ports for inst access
	// 	input	wire [ 8:0]	csr_waddr, 	// write address
	// 	input	wire [ 8:0]	csr_raddr,	// read  address
	// 	input	wire		csr_we, 	// write enable
	// 	input	wire [31:0]	csr_wmask, 	// write mask
	// 	input	wire [31:0]	csr_wvalue,	// value to be written
	// 	output	wire [31:0]	csr_rvalue,	// value read

	// 	// Ports for interacting with CPU hardware
	// 	input	wire [31:0] cpuid,		// CPU ID, just 0 is OK
	// 	input	wire [ 7:0]	hw_int_in, 	// hardware interrupt
	// 	input	wire		ipi_int_in, // IPI interrupt (0)
	// 	output	wire [31:0] ex_entry, 	// exception entry
	// 	output	wire		has_int, 	// has interrupt
	// 	output	wire [31:0]	era_value,	// exception return address
	// 	input	wire		ertn_flush, // ERTN inst (ertn)
	// 	input	wire		WB_ex, 		// exc from WB
	// 	input	wire [31:0] WB_pc,
	// 	input	wire [31:0] WB_vaddr, 	// bad vaddr
	// 	input	wire [ 5:0]	WB_ecode,	// exception code
	// 	input	wire [ 8:0] WB_esubcode
	// );

/* --------------------------------------------------------------------
	Pipeline control
  ------------------------------------------------------------------ */

	/* pre-if stage end */
	assign pipe_ready_go[0] = pipe_valid[0];
	assign pipe_ready_go[1] = pipe_valid[1] && !ID_hazard;
	assign pipe_ready_go[2] = pipe_valid[2] && calc_done;
	assign pipe_ready_go[3] = pipe_valid[3];
	assign pipe_ready_go[4] = pipe_valid[4];

	// judge whether the stage allows new instruction to enter
	assign pipe_allowin[Stage_Num - 2 : 0] =
		~pipe_valid[Stage_Num - 2 : 0] | pipe_ready_go[Stage_Num - 2 : 0] & pipe_allowin[Stage_Num - 1 : 1];
	assign pipe_allowin[Stage_Num - 1] =
		~pipe_valid[Stage_Num - 1] | pipe_ready_go[Stage_Num - 1];

	// judge whether the stage is ready to go
	assign pipe_tonext_valid[Stage_Num - 2 : 0] =
		pipe_allowin[Stage_Num - 1 : 1] & pipe_ready_go[Stage_Num - 2 : 0];

	// branch valid from WB stage
	wire br_from_WB = WB_ex || (has_int_WB || ertn_inst_WB) && pipe_valid[4];

	// valid signal control in pipeline
	always @(posedge clk) begin
		if (reset) begin
				pipe_valid <= 5'b00000;
		end
		else begin
			// IF stage
			if (pipe_allowin[0]) begin
				pipe_valid[0] <= 1'b1;
			end

			// ID stage
			if (br_taken || br_from_WB) begin
				pipe_valid[1] <= 1'b0;
			end
			else  begin
				if (pipe_allowin[1]) begin
					pipe_valid[1] <= pipe_ready_go[0];
				end
			end

			// EX stage
			if (br_from_WB) begin
				pipe_valid[2] <= 1'b0;
			end
			else if (br_taken) begin
				if (pipe_tonext_valid[2]) begin
					pipe_valid[2] <= 1'b0;
				end
			end
			else  begin
				if (pipe_allowin[2]) begin
					pipe_valid[2] <= pipe_ready_go[1];
				end
			end

			// MEM stage
			if (br_from_WB) begin
				pipe_valid[3] <= 1'b0;
			end
			else if (pipe_allowin[3]) begin
				pipe_valid[3] <= pipe_ready_go[2];
			end

			// WB stage
			if (br_from_WB) begin
				pipe_valid[4] <= 1'b0;
			end
			else if (pipe_allowin[4]) begin
				pipe_valid[4] <= pipe_ready_go[3];
			end
		end
	end

	/* pre-if stage begin */

	// next PC calculation
	assign seq_pc = pc + 3'h4; // PC+4, the next PC value.

	// next PC calculation
	assign nextpc = ertn_inst_WB && pipe_valid[4] ? era_value
				  : WB_ex        && pipe_valid[4] ? ex_entry
				  : br_taken                      ? br_target
				  :                                 seq_pc;

	// instruction memory (SRAM)
	assign inst_sram_en    = 1'b1;		// instruction memory enable
	assign inst_sram_we    = 4'b0000;	// instruction memory byte-writes
	assign inst_sram_addr  = {nextpc[31:2], 2'b00};	// instruction memory address
	assign inst_sram_wdata = `WIDTH'b0;	// instruction memory write data


/* --------------------------------------------------------------------
	Pipeline Hazard Control
  ------------------------------------------------------------------ */

	// register equality detection
	assign rd_EX_r1_eq  = (rf_raddr1 != `R0) && (rf_raddr1 == dest_EX)  && pipe_valid[2];
	assign rd_EX_r2_eq  = (rf_raddr2 != `R0) && (rf_raddr2 == dest_EX)  && pipe_valid[2];
	assign rd_MEM_r1_eq = (rf_raddr1 != `R0) && (rf_raddr1 == dest_MEM) && pipe_valid[3];
	assign rd_MEM_r2_eq = (rf_raddr2 != `R0) && (rf_raddr2 == dest_MEM) && pipe_valid[3];
	assign rd_WB_r1_eq  = (rf_raddr1 != `R0) && (rf_raddr1 == dest_WB)  && pipe_valid[4];
	assign rd_WB_r2_eq  = (rf_raddr2 != `R0) && (rf_raddr2 == dest_WB)  && pipe_valid[4];

	// hazard detection
	assign hzd_alu_EX_r1  = rd_EX_r1_eq  && gpr_we_EX  && !(ld_inst_EX || mul_inst_EX || csr_inst_EX);
	assign hzd_alu_EX_r2  = rd_EX_r2_eq  && gpr_we_EX  && !(ld_inst_EX || mul_inst_EX || csr_inst_EX);
	assign hzd_alu_MEM_r1 = rd_MEM_r1_eq && gpr_we_MEM && !(ld_inst_MEM || mul_inst_MEM || csr_inst_MEM);
	assign hzd_alu_MEM_r2 = rd_MEM_r2_eq && gpr_we_MEM && !(ld_inst_MEM || mul_inst_MEM || csr_inst_MEM);
	assign hzd_ld_mul_csr_EX_r1  = rd_EX_r1_eq  && (ld_inst_EX || mul_inst_EX || csr_inst_EX); // mul
	assign hzd_ld_mul_csr_EX_r2  = rd_EX_r2_eq  && (ld_inst_EX || mul_inst_EX || csr_inst_EX); // mul
	assign hzd_ld_mul_csr_MEM_r1 = rd_MEM_r1_eq && (ld_inst_MEM || mul_inst_MEM || csr_inst_MEM); // mul
	assign hzd_ld_mul_csr_MEM_r2 = rd_MEM_r2_eq && (ld_inst_MEM || mul_inst_MEM || csr_inst_MEM); // mul
	assign hzd_WB_r1 = rd_WB_r1_eq && gpr_we_WB, hzd_WB_r2 = rd_WB_r2_eq && gpr_we_WB;
	assign hzd_csrw_EX = pipe_valid[2] && csr_we_EX &&
		(csr_code_EX[8:0] == 9'h00 || csr_code_EX[8:0] == 9'h04 ||	// CRMD, ECFG
		csr_code_EX[8:0] == 9'h41 || csr_code_EX[8:0] == 9'h44),	// TCFG, TICLR
		hzd_csrw_MEM = pipe_valid[3] && csr_we_MEM &&
		(csr_code_MEM[8:0] == 9'h00 || csr_code_MEM[8:0] == 9'h04 ||	// CRMD, ECFG
		csr_code_MEM[8:0] == 9'h41 || csr_code_MEM[8:0] == 9'h44),	// TCFG, TICLR
		hzd_csrw_WB = pipe_valid[4] && csr_we_WB &&
		(csr_waddr[8:0] == 9'h00 || csr_waddr[8:0] == 9'h04 ||	// CRMD, ECFG
		csr_waddr[8:0] == 9'h41 || csr_waddr[8:0] == 9'h44);	// TCFG, TICLR
	

	/*assign hzd_rdcn_WB_r1 = rd_WB_r1_eq && rdcn_inst_WB && gpr_we_WB, hzd_rdcn_WB_r2 = rd_WB_r2_eq && rdcn_inst_WB && gpr_we_WB;*/

	// hazard that stalls ID stage
	assign ID_hazard = hzd_ld_mul_csr_EX_r1  && rf_ren1
					|| hzd_ld_mul_csr_EX_r2  && rf_ren2
					|| hzd_ld_mul_csr_MEM_r1 && rf_ren1
					|| hzd_ld_mul_csr_MEM_r2 && rf_ren2
					/*|| hzd_rdcn_WB_r1 && rf_ren1
					|| hzd_rdcn_WB_r2 && rf_ren2*/
					|| hzd_csrw_EX || hzd_csrw_MEM || hzd_csrw_WB
	;



/* --------------------------------------------------------------------
	Pipeline Stages Instantiation
  ------------------------------------------------------------------ */

/*
module stage_IF (
	input  wire                  clk,
	input  wire                  reset, // localized reset signal

	// input from stage controller
	input  wire                  pipe_allowin_IF, // allow IF stage to accept new instruction
	input  wire                  pipe_tonext_valid_IF, // IF stage is ready to go
	input  wire                  pipe_valid_IF, // IF stage is valid
	input  wire                  br_from_WB,
	input  wire [`WIDTH - 1 : 0] nextpc, // next PC value, branch target
	
	// input from pre-IF stage
	input  wire [`WIDTH - 1 : 0] inst_sram_rdata,	// instruction memory read data
	
	// input from EX stage
	input  wire                  br_taken, // branch taken or not
	
	// output to ID (not only)
	output wire [`WIDTH - 1 : 0] inst_final, // final instruction
	output wire [`WIDTH - 1 : 0] pc, // PC
	output wire [         5 : 0] ecode
);
*/
	stage_IF stage_IF_inst (
		.clk					(clk),
		.reset					(reset),

		.pipe_allowin_IF		(pipe_allowin[0]),
		.pipe_tonext_valid_IF	(pipe_tonext_valid[0]),
		.pipe_valid_IF			(pipe_valid[0]),
		.br_from_WB				(br_from_WB),
		.nextpc					(nextpc),

		.inst_sram_rdata		(inst_sram_rdata),

		.br_taken				(br_taken),

		.inst_final				(inst_final),
		.pc						(pc),
		.ecode					(ecode)
	);

/*
module stage_ID (
	input  wire                  clk,
	input  wire                  reset, // localized reset signal

	// input from stage controller
	input  wire                  pipe_tonext_valid_IF, pipe_tonext_valid_ID,
	input  wire                  hzd_alu_EX_r1, hzd_alu_MEM_r1, hzd_WB_r1,
	input  wire                  hzd_alu_EX_r2, hzd_alu_MEM_r2, hzd_WB_r2,
	input  wire [`WIDTH - 1 : 0] alu_result, alu_result_MEM, rf_wdata_WB,

	// input from IF stage
	input  wire [`WIDTH - 1 : 0] inst_final,
	input  wire [`WIDTH - 1 : 0] pc,
	input  wire [         5 : 0] ecode,

	// input from WB stage
	input  wire                  rf_we,		// register file write enable
	input  wire [`RADDR - 1 : 0] rf_waddr,	// register file write address
	input  wire [`WIDTH - 1 : 0] rf_wdata,	// register file write data

	// output to EX
	output wire [        12 : 0] alu_op,
	output wire [`WIDTH - 1 : 0] rj_value, rkd_value, imm,
	output wire [`WIDTH - 1 : 0] pc_ID,
	output wire [         3 : 0] op_25_22,
	output wire [         6 : 0] op_21_15,
	output wire [`RADDR - 1 : 0] rf_raddr1, rf_raddr2, dest,
	output wire 				 byte_we, half_we, word_we, signed_we,
	output wire                  ld_inst, st_inst, div_inst, mul_inst, ertn_inst, csr_inst,
	output wire                  br_taken_sure, br_taken_yes, br_taken_no,
	output wire                  src1_is_pc, src2_is_imm, src2_is_4, br_src_sel,
	output wire                  res_from_mem, gpr_we, mem_we,
	output wire                  rf_ren1, rf_ren2,
	output wire [         5 : 0] ecode_ID_m,
	output wire 				 csr_we, csr_wmask_en // csr write enable, csr write mask enable (inst_csrxchg)
};
*/
	stage_ID stage_ID_inst (
		.clk (clk),
		.reset (reset),

		.pipe_tonext_valid_IF (pipe_tonext_valid[0]), .pipe_tonext_valid_ID(pipe_tonext_valid[1]),
		.pipe_valid_ID(pipe_valid[1]),
		.hzd_alu_EX_r1 (hzd_alu_EX_r1), .hzd_alu_MEM_r1 (hzd_alu_MEM_r1), .hzd_WB_r1(hzd_WB_r1),
		.hzd_alu_EX_r2 (hzd_alu_EX_r2), .hzd_alu_MEM_r2 (hzd_alu_MEM_r2), .hzd_WB_r2(hzd_WB_r2),
		.alu_div_rdcntv_result (alu_div_rdcntv_result), .alu_div_rdcntv_result_MEM (alu_div_rdcntv_result_MEM), .rf_wdata_WB(rf_wdata),	/*These three are forwarding */
		.has_int(has_int),
		.EX_MEM_WB_ex_ertn(EX_ex_ertn || MEM_ex_ertn || br_from_WB),
		/*
		* If an instruction at EX or MEM is ertn or marked exception,
		* mark the instruction at ID as interrupt to wipe its effects.
		*/

		.inst_final (inst_final),
		.pc (pc),
		.ecode (ecode),

		.rf_we (rf_we),
		.rf_waddr (rf_waddr),
		.rf_wdata (rf_wdata),
	
		.alu_op (alu_op),
		.rj_value (rj_value), .rkd_value (rkd_value), .imm (imm),
		.pc_ID (pc_ID),
		.op_25_22 (op_25_22),
		.op_21_15 (op_21_15),
		.rf_raddr1 (rf_raddr1), .rf_raddr2 (rf_raddr2), .dest (dest),
		.byte_we (byte_we), .half_we (half_we), .word_we (word_we), .signed_we (signed_we),
		.ld_inst (ld_inst), .st_inst (st_inst), .div_inst (div_inst), .mul_inst (mul_inst), .ertn_inst (ertn_inst), .csr_inst (csr_inst), .rdcn_inst (rdcn_inst),
		.br_taken_sure (br_taken_sure), .br_taken_yes (br_taken_yes), .br_taken_no (br_taken_no),
		.src1_is_pc (src1_is_pc), .src2_is_imm (src2_is_imm), .src2_is_4 (src2_is_4), .br_src_sel(br_src_sel),
		.res_from_mem (res_from_mem), .gpr_we (gpr_we), .mem_we (mem_we),
		.rf_ren1 (rf_ren1), .rf_ren2 (rf_ren2),
		.ecode_ID_m (ecode_ID_m), .rdcn_op (rdcn_op),
		.csr_we (csr_we), .csr_wmask_en (csr_wmask_en), .has_int_ID(has_int_ID)
	);	
	
/*
module stage_EX (
	input  wire                  clk,
	input  wire                  reset, // localized reset signal

	// input from stage controller
	input  wire                  pipe_tonext_valid_ID, // allow EX stage to accept new instruction
	input  wire                  pipe_valid_EX, // EX stage is valid

	// input from ID
	input  wire [        12 : 0] alu_op,
	input  wire [`WIDTH - 1 : 0] rj_value, rkd_value, pc_ID, imm,
	input  wire [         3 : 0] op_25_22,
	input  wire [         6 : 0] op_21_15,
	input  wire [`RADDR - 1 : 0] rf_raddr1, rf_raddr2, dest,
	input  wire 				 byte_we, half_we, word_we, signed_we,
	input  wire                  ld_inst, st_inst, div_inst, mul_inst, csr_inst, ertn_inst,
	input  wire                  br_taken_sure, br_taken_yes, br_taken_no,
	input  wire                  src1_is_pc, src2_is_imm, src2_is_4, br_src_sel,
	input  wire                  res_from_mem, gpr_we, mem_we,
	input  wire [         5 : 0] ecode_ID_m,
	input  wire 				 csr_we, csr_wmask_en,

	// input from csr module 
	input  wire [`WIDTH - 1 : 0] ex_entry, era_value, // EX

	// output to MEM
	output wire [`WIDTH - 1 : 0] pc_EX, rj_value_EX, rkd_value_EX,
	output wire [`WIDTH - 1 : 0] alu_result, 
	output wire [`DWIDTH - 1: 0] mul_result,				// mul - to WB
	output wire [         3 : 0] op_25_22_EX,
	output wire [`RADDR - 1 : 0] rf_raddr1_EX, rf_raddr2_EX, dest_EX,
	output wire 				 byte_we_EX, half_we_EX, word_we_EX, signed_we_EX,
	output wire                  ld_inst_EX, st_inst_EX, csr_inst_EX, ertn_inst_EX,
	output wire                  mul_inst_EX,               // mul
	output wire [         2 : 0] mul_op_EX,                 // mul
	output wire                  res_from_mem_EX, gpr_we_EX, mem_we_EX,

	// output
	output wire [`WIDTH - 1 : 0] br_target, // next PC value, branch target
	output wire                  br_taken, calc_done,   // calculation ready, for mul/div instructions
	output wire [         5 : 0] ecode_EX_m,

	output wire 				 csr_we_EX, csr_wmask_en_EX,
	output wire [        13 : 0] csr_code
);
*/
	stage_EX stage_EX_inst (
		.clk (clk),
		.reset (reset),
	
		.pipe_tonext_valid_ID (pipe_tonext_valid[1]),
		.pipe_valid_EX (pipe_valid[2]), .tick(tick),
	
		.alu_op (alu_op),
		.rj_value (rj_value), .rkd_value (rkd_value), .pc_ID (pc_ID), .imm (imm),
		.op_25_22 (op_25_22),
		.op_21_15 (op_21_15),
		.rf_raddr1 (rf_raddr1), .rf_raddr2 (rf_raddr2), .dest (dest),
		.byte_we (byte_we), .half_we (half_we), .word_we (word_we), .signed_we (signed_we),
		.ld_inst (ld_inst), .st_inst (st_inst), .div_inst (div_inst), .mul_inst (mul_inst), .csr_inst (csr_inst),
		.ertn_inst (ertn_inst), .rdcn_inst (rdcn_inst),
		.br_taken_sure (br_taken_sure), .br_taken_yes (br_taken_yes), .br_taken_no (br_taken_no),
		.src1_is_pc (src1_is_pc), .src2_is_imm (src2_is_imm), .src2_is_4 (src2_is_4), .br_src_sel(br_src_sel),
		.res_from_mem (res_from_mem), .gpr_we (gpr_we), .mem_we (mem_we),
		.ecode_ID_m (ecode_ID_m), .rdcn_op (rdcn_op),
		.csr_we (csr_we), .csr_wmask_en (csr_wmask_en), .has_int_ID(has_int_ID),

		.ex_entry (ex_entry), .era_value (era_value),
	
		.pc_EX (pc_EX), .rj_value_EX (rj_value_EX), .rkd_value_EX (rkd_value_EX),
		.alu_div_rdcntv_result (alu_div_rdcntv_result), .mul_result (mul_result),
		.op_25_22_EX (op_25_22_EX),
		.rf_raddr1_EX (rf_raddr1_EX), .rf_raddr2_EX (rf_raddr2_EX), .dest_EX (dest_EX),
		.byte_we_EX (byte_we_EX), .half_we_EX (half_we_EX), .word_we_EX (word_we_EX), .signed_we_EX (signed_we_EX),
		.ld_inst_EX (ld_inst_EX), .st_inst_EX (st_inst_EX), .csr_inst_EX (csr_inst_EX), .ertn_inst_EX (ertn_inst_EX), .rdcn_inst_EX (rdcn_inst_EX),
		.mul_inst_EX (mul_inst_EX),
		.mul_op_EX (mul_op_EX),
		.res_from_mem_EX (res_from_mem_EX), .gpr_we_EX (gpr_we_EX), .mem_we_EX (mem_we_EX),
		.has_int_EX(has_int_EX), .EX_ex_ertn(EX_ex_ertn),

		.br_target (br_target), .br_taken (br_taken), .calc_done (calc_done),
		.ecode_EX_m (ecode_EX_m), .rdcn_op_EX (rdcn_op_EX),

		.csr_we_EX (csr_we_EX), .csr_wmask_en_EX (csr_wmask_en_EX),
		.csr_code_EX (csr_code_EX)
	);

/*
module stage_MEM (
	input  wire                  clk,
	input  wire                  reset, // localized reset signal

	// input from stage controller
	input  wire                  pipe_tonext_valid_EX, // allow MEM stage to accept new instruction
	input  wire                  pipe_valid_MEM, // MEM stage is valid

	// input from EX
	input  wire [`WIDTH - 1 : 0] pc_EX, alu_result, rj_value_EX, rkd_value_EX,
	input  wire [         3 : 0] op_25_22_EX,
	input  wire [`RADDR - 1 : 0] rf_raddr1_EX, rf_raddr2_EX, dest_EX,
	input  wire 				 byte_we_EX, half_we_EX, word_we_EX, signed_we_EX,
	input  wire                  ld_inst_EX, st_inst_EX, csr_inst_EX, ertn_inst_EX,
	input  wire					 mul_inst_EX, // mul
	input  wire [		  2 : 0] mul_op_EX, // mul
	input  wire                  res_from_mem_EX, gpr_we_EX, mem_we_EX,
	input  wire [         5 : 0] ecode_EX_m,
	input  wire 				 csr_we_EX, csr_wmask_en_EX,
	input  wire [        13 : 0] csr_code,
	input  wire 				 br_from_WB, // branch valid signal, at WB stage, calculated in cpu_top

	// output to WB
	output wire [`WIDTH - 1 : 0] pc_MEM, alu_result_MEM, rj_value_MEM, rkd_value_MEM,
	output wire [`RADDR - 1 : 0] rf_raddr1_MEM, rf_raddr2_MEM, dest_MEM,
	output wire [         3 : 0] mask_dataram,
	output wire 				 byte_we_MEM, half_we_MEM, word_we_MEM, signed_we_MEM,
	output wire 				 ld_inst_MEM, csr_inst_MEM, ertn_inst_MEM,
	output wire					 mul_inst_MEM, // mul
	output wire [		  2 : 0] mul_op_MEM, // mul
	output wire 				 res_from_mem_MEM, gpr_we_MEM,

	// output
	output wire                  data_sram_en,	// data SRAM port enable pin
	output wire [         3 : 0] data_sram_we,	// data SRAM byte-writes
	output wire [`WIDTH - 1 : 0] data_sram_addr, data_sram_wdata,
	output wire [         5 : 0] ecode_MEM_m,
	output wire 				 csr_we_MEM, csr_wmask_en_MEM,
	output wire [        13 : 0] csr_code_MEM
);
*/
	stage_MEM stage_MEM_inst (
		.clk (clk),
		.reset (reset),

		.pipe_tonext_valid_EX (pipe_tonext_valid[2]),
		.pipe_valid_MEM (pipe_valid[3]),

		.pc_EX (pc_EX), .alu_div_rdcntv_result (alu_div_rdcntv_result), .rj_value_EX (rj_value_EX), .rkd_value_EX (rkd_value_EX),
		.op_25_22_EX (op_25_22_EX),
		.rf_raddr1_EX (rf_raddr1_EX), .rf_raddr2_EX (rf_raddr2_EX), .dest_EX (dest_EX),
		.byte_we_EX (byte_we_EX), .half_we_EX (half_we_EX), .word_we_EX (word_we_EX), .signed_we_EX (signed_we_EX),
		.ld_inst_EX (ld_inst_EX), .st_inst_EX (st_inst_EX), .csr_inst_EX (csr_inst_EX), .ertn_inst_EX (ertn_inst_EX), .rdcn_inst_EX (rdcn_inst_EX),
		.mul_inst_EX (mul_inst_EX), .mul_op_EX (mul_op_EX), .rdcn_op_EX (rdcn_op_EX),
		.res_from_mem_EX (res_from_mem_EX), .gpr_we_EX (gpr_we_EX), .mem_we_EX (mem_we_EX),
		.ecode_EX_m (ecode_EX_m),
		.csr_we_EX (csr_we_EX), .csr_wmask_en_EX (csr_wmask_en_EX),
		.csr_code_EX (csr_code_EX),
		.br_from_WB (br_from_WB),
		.has_int_EX (has_int_EX),

		.pc_MEM (pc_MEM), .alu_div_rdcntv_result_MEM (alu_div_rdcntv_result_MEM), .rj_value_MEM (rj_value_MEM), .rkd_value_MEM (rkd_value_MEM),
		.rf_raddr1_MEM (rf_raddr1_MEM), .rf_raddr2_MEM (rf_raddr2_MEM), .dest_MEM (dest_MEM),
		.mask_dataram (mask_dataram),
		.byte_we_MEM (byte_we_MEM), .half_we_MEM (half_we_MEM), .word_we_MEM (word_we_MEM), .signed_we_MEM (signed_we_MEM),
		.ld_inst_MEM (ld_inst_MEM), .csr_inst_MEM (csr_inst_MEM), .ertn_inst_MEM (ertn_inst_MEM), .rdcn_inst_MEM (rdcn_inst_MEM),
		
		.mul_inst_MEM (mul_inst_MEM), .mul_op_MEM (mul_op_MEM), .rdcn_op_MEM (rdcn_op_MEM),
		.res_from_mem_MEM (res_from_mem_MEM), .gpr_we_MEM (gpr_we_MEM),
		.has_int_MEM (has_int_MEM), .MEM_ex_ertn(MEM_ex_ertn),

		.data_sram_en (data_sram_en),
		.data_sram_we (data_sram_we),
		.data_sram_addr (data_sram_addr), .data_sram_wdata (data_sram_wdata),
		.ecode_MEM_m (ecode_MEM_m),
		.csr_we_MEM (csr_we_MEM), .csr_wmask_en_MEM (csr_wmask_en_MEM),
		.csr_code_MEM (csr_code_MEM)
	);
	

/*
module stage_WB (
	input  wire                  clk,
	input  wire                  reset, // localized reset signal

	// input from stage controller
	input  wire                  pipe_tonext_valid_MEM, // allow WB stage to accept new instruction
	input  wire                  pipe_valid_WB, // WB stage is valid
	input  wire [`WIDTH - 1 : 0] data_sram_rdata,
	input  wire 				 time_interupt,

	// input from MEM
	input  wire [`WIDTH - 1 : 0] pc_MEM, alu_result_MEM, rj_value_MEM, rkd_value_MEM,
	input  wire [`DWIDTH - 1: 0] mul_result,   // mul
	input  wire [`RADDR - 1 : 0] rf_raddr1_MEM, rf_raddr2_MEM, dest_MEM,
	input  wire [         3 : 0] mask_dataram,
	input  wire                  byte_we_MEM, half_we_MEM, word_we_MEM, signed_we_MEM,
	input  wire					 csr_inst_MEM, ertn_inst_MEM,
	input  wire					 mul_inst_MEM, // mul
	input  wire [ 		  2 : 0] mul_op_MEM, // mul
	input  wire                  res_from_mem_MEM, gpr_we_MEM,
	input  wire [         5 : 0] ecode_MEM_m,
	input  wire 				 csr_we_MEM, csr_wmask_en_MEM,
	input  wire [        13 : 0] csr_code_MEM,
	// input  wire [`WIDTH - 1 : 0] csr_rvalue_MEM,

	// input from csr module
	input  wire [`WIDTH - 1 : 0] csr_rvalue,


	// output
	output wire                  gpr_we_WB,

	output wire                  rf_we,			// register file write enable
	output wire [`RADDR - 1 : 0] rf_waddr,		// register file write address
	output wire [`RADDR - 1 : 0] dest_WB,		// destination register number
	output wire [`WIDTH - 1 : 0] rf_wdata,		// register file write data

	output wire [`WIDTH - 1 : 0] pc_WB,
	output wire [         3 : 0] debug_wb_rf_we,	// debug info
	output wire [`RADDR - 1 : 0] debug_wb_rf_wnum,	// debug info
	output wire [`WIDTH - 1 : 0] debug_wb_rf_wdata,	// debug info
	
	output wire [         8 : 0] csr_waddr,
	output wire 				 csr_we,
	output wire [`WIDTH - 1 : 0] csr_wmask,
	output wire [`WIDTH - 1 : 0] csr_wvalue,
	output wire [         8 : 0] csr_raddr,
	output wire 				 ertn_flush,
	output wire 				 WB_ex,
	output wire [        31 : 0] WB_vaddr,
	output wire [         5 : 0] ecode_noint, // ecode, without considering interrupt
	output wire [         8 : 0] WB_esubcode,

	output wire 				 ertn_inst_WB
);
*/
	stage_WB stage_WB_inst (
		.clk (clk),
		.reset (reset),

		.pipe_tonext_valid_MEM (pipe_tonext_valid[3]),
		.pipe_valid_WB (pipe_valid[4]),
		.data_sram_rdata (data_sram_rdata),
		.time_interupt (time_interupt),

		.pc_MEM (pc_MEM), .alu_div_rdcntv_result_MEM (alu_div_rdcntv_result_MEM), .rj_value_MEM (rj_value_MEM), .rkd_value_MEM (rkd_value_MEM),
		.mul_result (mul_result),
		.rf_raddr1_MEM (rf_raddr1_MEM), .rf_raddr2_MEM (rf_raddr2_MEM), .dest_MEM (dest_MEM),
		.mask_dataram (mask_dataram),
		.byte_we_MEM (byte_we_MEM), .half_we_MEM (half_we_MEM), .word_we_MEM (word_we_MEM), .signed_we_MEM (signed_we_MEM),
		.csr_inst_MEM (csr_inst_MEM), .ertn_inst_MEM (ertn_inst_MEM), .rdcn_inst_MEM (rdcn_inst_MEM),
		.mul_inst_MEM (mul_inst_MEM), .mul_op_MEM (mul_op_MEM), .rdcn_op_MEM (rdcn_op_MEM),
		.res_from_mem_MEM (res_from_mem_MEM), .gpr_we_MEM (gpr_we_MEM),
		.ecode_MEM_m (ecode_MEM_m),
		.csr_we_MEM (csr_we_MEM), .csr_wmask_en_MEM (csr_wmask_en_MEM),
		.csr_code_MEM (csr_code_MEM), .has_int_MEM (has_int_MEM),

		.csr_rvalue (csr_rvalue),

		.gpr_we_WB (gpr_we_WB),
		
		.rf_we (rf_we),
		.rf_waddr (rf_waddr),
		.dest_WB (dest_WB),
		.rf_wdata (rf_wdata),

		.pc_WB (pc_WB),
		.debug_wb_rf_we (debug_wb_rf_we),
		.debug_wb_rf_wnum (debug_wb_rf_wnum),
		.debug_wb_rf_wdata (debug_wb_rf_wdata),

		.csr_waddr (csr_waddr),
		.csr_we (csr_we_WB),
		.csr_wmask (csr_wmask),
		.csr_wvalue (csr_wvalue),
		.csr_raddr (csr_raddr),
		.ertn_flush (ertn_flush),
		.WB_ex (WB_ex),
		.WB_vaddr (WB_vaddr),
		.ecode_noint (ecode_noint),
		.WB_esubcode (WB_esubcode),

		.ertn_inst_WB (ertn_inst_WB),
		.has_int_WB (has_int_WB),
		.rdcn_inst_WB (rdcn_inst_WB)
	);


endmodule
