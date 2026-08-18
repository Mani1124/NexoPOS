<?php

namespace App\Console\Commands;

use App\Models\Customer;
use App\Models\CustomerGroup;
use App\Models\Procurement;
use App\Models\Product;
use App\Models\ProductCategory;
use App\Models\Provider;
use App\Models\Register;
use App\Models\Role;
use App\Models\User;
use App\Services\DemoService;
use Illuminate\Console\Command;
use Illuminate\Support\Facades\Auth;

class ImportSampleDataCommand extends Command
{
    /**
     * The name and signature of the console command.
     *
     * @var string
     */
    protected $signature = 'ns:import-sample-data
        {--force : Import even if the data already exists}
        {--accounts : Create the default accounting accounts}
        {--units : Prepare the default unit system}
        {--taxes : Create sample taxes}
        {--customers : Import customers and customer groups}
        {--providers : Import the default provider}
        {--registers : Create the POS registers}
        {--products : Import sample products and categories}
        {--procurement : Add stock to existing products}';

    /**
     * The console command description.
     *
     * @var string
     */
    protected $description = 'Import sample data (products, customers, etc.) without resetting the store.';

    /**
     * Execute the console command.
     */
    public function handle( DemoService $demoService )
    {
        $admin = Role::namespace( 'admin' )->users()->first();

        if ( ! $admin instanceof User ) {
            $this->error( 'No admin user found. Make sure the store is installed.' );

            return Command::FAILURE;
        }

        Auth::loginUsingId( $admin->id );

        $force = $this->option( 'force' );
        $specific = $this->hasSpecificOption();

        if ( $this->option( 'accounts' ) || ! $specific ) {
            $demoService->createAccountingAccounts();
            $this->info( 'Default accounting accounts created.' );
        }

        if ( $this->option( 'units' ) || ! $specific ) {
            $demoService->prepareDefaultUnitSystem();
            $this->info( 'Default unit system ready.' );
        }

        if ( $this->option( 'taxes' ) || ! $specific ) {
            $demoService->createTaxes();
            $this->info( 'Sample taxes created.' );
        }

        if ( $this->option( 'customers' ) || ! $specific ) {
            if ( $force || CustomerGroup::count() === 0 ) {
                $demoService->createCustomers();
                $this->info( 'Customers imported: ' . Customer::count() );
            } else {
                $this->warn( 'Customers already exist. Use --force to import anyway.' );
            }
        }

        if ( $this->option( 'providers' ) || ! $specific ) {
            if ( $force || Provider::count() === 0 ) {
                $demoService->createProviders();
                $this->info( 'Default provider imported.' );
            } else {
                $this->warn( 'Provider already exists. Use --force to import anyway.' );
            }
        }

        if ( $this->option( 'registers' ) || ! $specific ) {
            if ( $force || Register::count() === 0 ) {
                $demoService->createRegisters();
                $this->info( 'POS registers imported: ' . Register::count() );
            } else {
                $this->warn( 'Registers already exist. Use --force to import anyway.' );
            }
        }

        if ( $this->option( 'products' ) || ! $specific ) {
            if ( $force || Product::count() === 0 ) {
                $demoService->createProducts();
                $this->info( 'Products imported: ' . Product::count() . ' (categories: ' . ProductCategory::count() . ')' );
            } else {
                $this->warn( 'Products already exist. Use --force to import anyway.' );
            }
        }

        if ( $this->option( 'procurement' ) || ! $specific ) {
            if ( Product::count() === 0 || Provider::count() === 0 ) {
                $this->warn( 'Stock not added: products and a provider are required. Import them first.' );
            } elseif ( $force || ! $this->hasProcurement() ) {
                $demoService->performProcurement();
                $this->info( 'Stock added to products.' );
            } else {
                $this->warn( 'Stock already available. Use --force to add more.' );
            }
        }

        return Command::SUCCESS;
    }

    private function hasSpecificOption(): bool
    {
        foreach ( [ 'accounts', 'units', 'taxes', 'customers', 'providers', 'registers', 'products', 'procurement' ] as $option ) {
            if ( $this->option( $option ) ) {
                return true;
            }
        }

        return false;
    }

    private function hasProcurement(): bool
    {
        return Procurement::count() > 0;
    }
}
