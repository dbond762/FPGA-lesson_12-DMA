#include "xparameters.h"
#include <xstatus.h>
#include "xgpio.h"
#include "sleep.h"
#include "xaxidma.h"

#define BTN_BASEADDR XPAR_AXI_GPIO_0_BASEADDR
#define DMA_BASEADDR XPAR_AXI_DMA_0_BASEADDR
#define RAM_BASE     XPAR_AXI4_FULL_RAM_0_BASEADDR

#ifdef SIMULATION
  #define DEBOUNCE_US 0
#else
  #define DEBOUNCE_US 20000
#endif

#define CAPTURE_BTN_MASK 0x1U
#define FRAME_WORDS      16000U

static XGpio   btn_gpio;
static XAxiDma dma;

static u8 button_pressed( void )
{
    if ( XGpio_DiscreteRead(&btn_gpio, 1U) & CAPTURE_BTN_MASK )
    {
        usleep( DEBOUNCE_US );
        if ( XGpio_DiscreteRead(&btn_gpio, 1U) & CAPTURE_BTN_MASK )
        {
            return TRUE;
        }
    }
    return FALSE;
}

static XStatus setupGpio()
{
    XGpio_Config *cfg = XGpio_LookupConfig( BTN_BASEADDR );
    if ( cfg == NULL )
    {
        return XST_FAILURE;
    }

    XStatus status = XST_SUCCESS;

    status = XGpio_CfgInitialize( &btn_gpio, cfg, cfg->BaseAddress );
    if ( status != XST_SUCCESS )
    {
        return status;
    }

    XGpio_SetDataDirection( &btn_gpio, 1U, 0x01U );
    XGpio_SetDataDirection( &btn_gpio, 2U, 0x00U );

    return XST_SUCCESS;
}

static XStatus setupDma( void )
{
    XAxiDma_Config *cfg = XAxiDma_LookupConfig( DMA_BASEADDR );
    if ( cfg == NULL )
    {
        return XST_FAILURE;
    }
    XAxiDma_CfgInitialize( &dma, cfg );
    if ( XAxiDma_HasSg( &dma ) )
    {
        return XST_FAILURE;
    }

    return XST_SUCCESS;
}

int main( void )
{
    XStatus status = setupGpio();
    if ( status != XST_SUCCESS )
    {
        return status;
    }

    status = setupDma();
    if ( status != XST_SUCCESS )
    {
        return status;
    }

    while ( TRUE )
    {
        if ( button_pressed() )
        {
            XAxiDma_SimpleTransfer(&dma, RAM_BASE, FRAME_WORDS * 4U, XAXIDMA_DEVICE_TO_DMA);
            XGpio_DiscreteWrite( &btn_gpio, 2U, 0x1U );

            while ( XAxiDma_Busy( &dma, XAXIDMA_DEVICE_TO_DMA ) )
            {
            }

            XGpio_DiscreteWrite( &btn_gpio, 2U, 0x0U );
        }
    }
    
    return XST_SUCCESS;
}
